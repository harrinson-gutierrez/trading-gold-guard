//+------------------------------------------------------------------+
//| Cerberus.mq4 - MQL4 port of Cerberus (guardian + ORACLE) |
//| |
//| v2.0 (2026-07-23): SIMPLIFIED AND ALIGNED TO ORACLE 2.0. |
//| Removed - every mechanism that CLOSES a position early: |
//| rule A (adverse pips), rule B (margin level), rule C |
//| (volatility breaker), rule D (USD per position), the |
//| close-all on a news window, the Friday pre-close flatten |
//| and the whole scheduler. Measured 2026-07-23, those forced |
//| cuts are why avg_loss was -$3.58 against Oracle's -$1.78 |
//| while WINNING more often (66.5% vs 62%). |
//| Kept - the two nets the owner chose deliberately: |
//| rule E (daily loss -> close all + pause until RESUME) and |
//| an OPTIONAL per-basket USD stop, default OFF like Oracle. |
//| Display only, never blocking: hour-risk band, weekly-close |
//| warning. News blocks NEW entries only. |
//| ORACLE (magics 7799/9977): MA34 on OPEN + Gann HiLo(3) EMA on |
//| M1, additive grid, shared basket TP re-anchored to the |
//| weighted average. With BOTH engines on, magic 7799 takes |
//| SELL and 9977 takes BUY - as MEASURED on Oracle 2.0, which |
//| is the reverse of its own cosmetic labels. |
//| |
//| Pip scale for the strategy: 1 pip = Point*10 (XAUUSDm: $0.01). |
//| Requires hedging-style MT4 account and the WebRequest URL |
//| https://nfs.faireconomy.media whitelisted (Options->Experts). |
//+------------------------------------------------------------------+
#property copyright "Harrinson Gutierrez"
#property version   "2.00"
#property strict

#import "user32.dll"
   int GetAncestor(int hWnd, int gaFlags);
   int PostMessageW(int hWnd, int Msg, int wParam, int lParam);
#import
#define WM_COMMAND 0x0111
#define MT4_CMD_AUTOTRADING 33020

//==================================================================
// Inputs - Oracle 2.0 layout: the 9 knobs that get tuned live sit at the top,
// everything else is grouped behind an `input string` separator (the same
// pattern Oracle uses: "------Config Grid------"). Rule for labels: the visible
// text must read like the variable name, in English.
//==================================================================
input string __MAIN__            = "======== MAIN ========";
input string Symbol_Traded       = "XAUUSDm"; // Symbol to trade
input int    TakeProfit_Pips     = 15;     // Take Profit (pips)
input int    GridStep_Pips       = 100;    // Grid Step (pips)
input double Lot_Fixed           = 0.01;   // Fixed Lot
input double Lot_Factor          = 1.0;    // Lot Factor (1.0 = additive)
input int    MaxSpread_Points    = 240;    // Max Spread (points, 0 = off)
input int    MaxGrid_Levels      = 0;      // Max Grid Levels per engine (0 = capital-proportional cap)
input double DailyLoss_USD       = 200.0;  // Daily Loss -> close all + pause (USD, 0 = off)
input double BasketStop_USD      = 0;      // Basket Stop (USD, 0 = off)

input string __SIGNAL__          = "======== SIGNAL ========";
input int    Signal_TF           = 1;      // Signal Timeframe (minutes; 1 = M1)
input int    MA_Period           = 34;     // MA Period
input int    MA_Method           = 1;      // MA Method (1 = EMA, else SMA)
input int    MA_AppliedPrice     = 1;      // MA Applied Price (0=Close 1=Open) - Oracle uses Open
input int    HiLo_Period         = 3;      // HiLo Period
input int    HiLo_Method         = 1;      // HiLo Method (1 = EMA, else SMA) - Oracle uses EMA
input int    TrendBrake_MaxDistPips = 120; // Trend brake: block NEW entries AND adds while price is more than N pips ($0.10 each = $12 at 120) from the MA (a strong directional move). 0 = off. Fading a runaway trend is what buries the basket; Oracle stays quiet, opening ~1/min while Cerberus was opening 2-6/min into the same move. Lowered 150->120 so gradual grinds (where the MA follows the price down) get braked earlier, not just fast spikes.

input string __NEWS__            = "======== NEWS (blocks entries only) ========";
input int    News_MinutesBefore  = 30;     // News Minutes Before event
input int    News_MinutesAfter   = 45;     // News Minutes After event
input int    News_RefreshMinutes = 60;     // News Refresh (minutes)
input string News_TestMinutes    = "";     // News Test: fake USD event N min ahead (or TEST=N command)

input string __DISPLAY__         = "======== DISPLAY ONLY (never blocks) ========";
input bool   Show_HourRisk       = true;   // Show Hour Risk band on the panel
input bool   Show_SessionWarning = true;   // Show Session Warning before the weekly close
input int    SessionClose_HourGMT = 21;    // Session Close Hour GMT (gold/FX weekly close)
input int    SessionWarn_Min     = 5;      // Session Warning minutes ahead of the close

input string __ADVANCED__        = "======== ADVANCED ========";
input bool   Engine_A_Sell       = true;   // Engine A (magic 7799) = SELL
input bool   Engine_B_Buy        = true;   // Engine B (magic 9977) = BUY
input double MaxLot_Total        = 99.0;   // Max Lot total per basket
input int    MinSecs_BetweenAdds = 2;      // Min Seconds Between Adds (0 = off). The timer AND ticks run the grid; without a gap a tick burst stacks several levels before the fresh order is visible, violating GridStep.
input int    BasketStop_CooldownMin = 30;  // Basket Stop Cooldown (minutes)
input bool   BasketStop_ServerSL = true;   // Basket Stop also arms a server-side SL (no-op when BasketStop_USD = 0)
input double Capital_Base        = 1000;   // Capital Base for the proportional depth cap
input double Capital_PerLevel    = 180;    // Capital per grid Level (0 = no proportional cap)
input int    OpenWarmup_Min      = 3;      // Open Warmup: veto entries N min after a session (re)open
input int    ServerBlock_Min     = 10;     // Server Block backoff (minutes; broker refused trading)
input int    LocalBlock_Sec      = 10;     // Local Block backoff (seconds; err 4109/4110/4111)
input bool   ClosePendingOrders  = true;   // Close Pending Orders too on a close-all
input string Log_FileName        = "Cerberus_log.csv"; // Log File Name

//==================================================================
// Globals
//==================================================================
#define MAGIC_A 7799
#define MAGIC_B 9977
#define GV_PAUSE     "NG_ManualPause"
#define GV_GUARD     "NG_DisabledByGuard"   // news turned AT off (separate from scheduler's g_schedHardLock so they don't fight over the button)
#define GV_DAYDATE   "NG_DayDate"
#define GV_DAYBAL    "NG_DayStartBal"
#define GV_OV_TP     "CB4_ovTP"
#define GV_OV_GRID   "CB4_ovGrid"
#define GV_OV_LOT    "CB4_ovLot"
#define GV_OV_FACTOR "CB4_ovFactor"
#define GV_OV_MAXLEV "CB4_ovMaxLev"
#define GV_OV_BSTOP  "CB4_ovBstop"
#define GV_ORACLE_ON "CB4_OracleOn"
// The Gann HiLo Activator is a STATEFUL indicator: its side persists until price
// crosses the opposite band. A plain global resets to 0 on every OnInit, so after
// each terminal restart the bias silently fell back to the MA side until the first
// flip - a different state, not a neutral one, and nothing in the log said so.
// Persisting it in a GV keeps the indicator's memory across restarts.
// (Defect logged "pendiente" in docs/comparativa-cerberus-oracle-2026-07-21.md.)
#define GV_HILO_SIDE "CB4_hiloSide"
#define STATUS_FILE  "ng_status.json"
#define COMMAND_FILE "ng_command.txt"

string   g_sym = "";             // traded symbol
bool     g_oracleOn = true;
bool     g_paused = false;       // manual / rule E pause
datetime g_srvBlockUntil = 0;    // server-rejection backoff
datetime g_bstopUntil[2];        // per-engine basket-stop cooldown
datetime g_lastAddTime[2];       // GMT of the last level opened per engine (add throttle)
datetime g_openedAt = 0;         // last closed->open transition (warm-up)
bool     g_sawClosed = false;
bool     g_wasInWindow = false;  // news: were we inside a news window on the previous pass
string   g_activeEventName = ""; // news: name of the event currently pausing us
int      g_bstopHitsToday = 0;
datetime g_lastFeed = 0;
datetime g_lastFeedOk = 0;       // last SUCCESSFUL feed (panel "Feed: OK (age)")
datetime g_nextEvent = 0;        // nearest watched High event (0 = none)
string   g_nextEventTxt = "";
string   g_evTitle[64];          // event titles (panel NEXT line)
string   g_feedStatus = "-";
double   g_ovTP = -1, g_ovGrid = -1, g_ovLot = -1, g_ovFactor = -1, g_ovBstop = -1;
int      g_ovMaxLev = -1;

double EffTP()     { return (g_ovTP    > 0) ? g_ovTP    : TakeProfit_Pips; }
double EffGrid()   { return (g_ovGrid  > 0) ? g_ovGrid  : GridStep_Pips; }
double EffLot()    { return (g_ovLot   > 0) ? g_ovLot   : Lot_Fixed; }
double EffFactor() { return (g_ovFactor > 0) ? g_ovFactor : Lot_Factor; }
int    EffMaxLev() { return (g_ovMaxLev >= 0) ? g_ovMaxLev : MaxGrid_Levels; }
double EffBstop()  { return (g_ovBstop >= 0) ? g_ovBstop : BasketStop_USD; }

// Side each engine takes when BOTH are on. Oracle 2.0 runs magic 7799 SHORT and
// magic 9977 LONG - measured 1 Hz on 2026-07-21 (docs/comparativa §3.2), which is
// the reverse of its own cosmetic "Engine A [BUY]" labels AND the reverse of what
// this port did until v2.0. Corrected for fidelity and so per-magic metrics are
// comparable between the two bots; with one engine per side the swap is P/L-neutral.
int EngineSide(int magic) { return (magic == MAGIC_A) ? -1 : 1; }

//==================================================================
// Utilities
//==================================================================
string g_lastAction = "-";
void LogAction(string action, string detail)
{
   if (action != "INIT" && action != "DEINIT") g_lastAction = detail;
   int h = FileOpen(Log_FileName, FILE_READ | FILE_WRITE | FILE_TXT | FILE_ANSI);
   if (h == INVALID_HANDLE) { Print("LOG FAIL ", action, " | ", detail); return; }
   FileSeek(h, 0, SEEK_END);
   FileWriteString(h, TimeToString(TimeGMT(), TIME_DATE | TIME_SECONDS) + ";" + action + ";" + detail + "\r\n");
   FileClose(h);
   Print("Cerberus4: ", action, " | ", detail);
}

// Strategy pip: 10 points for 3/5/6-digit symbols (gold, most FX), 1 point
// otherwise. On XAUUSDm (3 digits) this is point*10 = $0.01.
double StratPip(string sym)
{
   double pt = MarketInfo(sym, MODE_POINT);
   int    dg = (int)MarketInfo(sym, MODE_DIGITS);
   return (dg == 3 || dg == 5 || dg == 6) ? pt * 10.0 : pt;
}

bool IsOurMagic(int m) { return (m == MAGIC_A || m == MAGIC_B); }
int  EngineIdx(int m)  { return (m == MAGIC_A) ? 0 : 1; }

// Close one ticket: up to 3 attempts with
// a quote refresh between them. The MT4 port had lost that loop, so a single
// transient rejection killed the close: on 2026-07-21 00:26:30 a basket-stop cut
// failed with err 136 (off quotes) and the position survived its own stop.
bool ClosePosition(int ticket, string reason)
{
   for (int attempt = 1; attempt <= 3; attempt++)
   {
      if (!OrderSelect(ticket, SELECT_BY_TICKET)) return false;
      if (OrderCloseTime() > 0) return true;   // already closed (by TP/SL or a previous attempt)
      RefreshRates();
      bool ok = false;
      double lots = OrderLots(); string sym = OrderSymbol();
      if (OrderType() == OP_BUY)  ok = OrderClose(ticket, lots, MarketInfo(sym, MODE_BID), 300, clrRed);
      if (OrderType() == OP_SELL) ok = OrderClose(ticket, lots, MarketInfo(sym, MODE_ASK), 300, clrRed);
      if (OrderType() > OP_SELL)  ok = OrderDelete(ticket);
      if (ok)
      {
         if (OrderSelect(ticket, SELECT_BY_TICKET, MODE_HISTORY))
            LogAction("ORDER_CLOSED", StringFormat("#%d %s %.2f lots P/L=%.2f (%s)",
                      ticket, sym, lots, OrderProfit() + OrderSwap() + OrderCommission(), reason));
         return true;
      }
      int err = GetLastError();
      LogAction("ORDER_CLOSE_FAIL", StringFormat("#%d attempt %d err=%d (%s)", ticket, attempt, err, reason));
      if (err == 133 || err == 4059 || err == 132)   // trade disabled / market closed: does not clear in this pass
      {
         g_srvBlockUntil = TimeGMT() + ServerBlock_Min * 60;
         return false;
      }
      if (err == 4109 || err == 4110 || err == 4111) return false;   // local permission: retried by the caller's next pass
      Sleep(500);   // 136 off quotes / 138 requote / 146 context busy: worth another try
   }
   return false;
}

void CloseEverything(string reason)
{
   for (int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if (!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if (OrderType() > OP_SELL && !ClosePendingOrders) continue;   // pendings only when allowed
      ClosePosition(OrderTicket(), reason);
   }
}

//==================================================================
// News feed (ForexFactory weekly JSON + disk cache)
//==================================================================
bool FeedOk = false;
int  g_eventsLoaded = 0;
datetime g_eventTimes[64];

datetime ParseFFDate(string s)  // "2026-07-20T08:30:00-04:00"
{
   if (StringLen(s) < 19) return 0;
   int y  = (int)StringToInteger(StringSubstr(s, 0, 4));
   int mo = (int)StringToInteger(StringSubstr(s, 5, 2));
   int d  = (int)StringToInteger(StringSubstr(s, 8, 2));
   int hh = (int)StringToInteger(StringSubstr(s, 11, 2));
   int mi = (int)StringToInteger(StringSubstr(s, 14, 2));
   datetime t = StringToTime(StringFormat("%04d.%02d.%02d %02d:%02d", y, mo, d, hh, mi));
 // apply the numeric UTC offset at the tail (+HH:MM / -HH:MM / Z)
   int off = 0;
   int n = StringLen(s);
   if (n >= 25)
   {
      string tail = StringSubstr(s, n - 6, 6);
      int oh = (int)StringToInteger(StringSubstr(tail, 1, 2));
      int om = (int)StringToInteger(StringSubstr(tail, 4, 2));
      off = oh * 3600 + om * 60;
      if (StringSubstr(tail, 0, 1) == "-") off = -off;
   }
   return t - off;   // to GMT
}

void ParseCalendar(string json)
{
   g_eventsLoaded = 0; g_nextEvent = 0; g_nextEventTxt = "";
   int pos = 0;
   while (g_eventsLoaded < 64)
   {
      int ip = StringFind(json, "\"impact\":\"High\"", pos);
      if (ip < 0) break;
      int start = ip; while (start > 0 && StringGetChar(json, start) != '{') start--;
      int endb = StringFind(json, "}", ip); if (endb < 0) break;
      string obj = StringSubstr(json, start, endb - start + 1);
      pos = endb + 1;
 // ALL currencies, not just USD - Oracle's feed has no country filter, it
 // pauses on any High-impact event (measured: this week 0 USD-High but 11
 // High across CAD/GBP/AUD/EUR incl. the ECB, which Oracle respects and the
 // old USD-only Cerberus ignored). Gold reacts to every major central bank.
      int dp = StringFind(obj, "\"date\":\"");
      if (dp < 0) continue;
      int dq = StringFind(obj, "\"", dp + 8);
      datetime t = ParseFFDate(StringSubstr(obj, dp + 8, dq - dp - 8));
      if (t <= 0) continue;
      string ccy = "";
      int cp = StringFind(obj, "\"country\":\"");
      if (cp < 0) cp = StringFind(obj, "\"currency\":\"");
      if (cp >= 0) { int cs = StringFind(obj, "\"", cp + 10) + 1; int ce = StringFind(obj, "\"", cs); ccy = StringSubstr(obj, cs, ce - cs); }
      string title = "";
      int tp = StringFind(obj, "\"title\":\"");
      if (tp >= 0) { int tq = StringFind(obj, "\"", tp + 9); title = StringSubstr(obj, tp + 9, tq - tp - 9); }
      g_evTitle[g_eventsLoaded] = (ccy != "" ? ccy + " " : "") + title;
      g_eventTimes[g_eventsLoaded++] = t;
   }
 // nearest upcoming (any currency), carrying its title for the pause message
   for (int i = 0; i < g_eventsLoaded; i++)
      if (g_eventTimes[i] > TimeGMT() - News_MinutesAfter * 60)
         if (g_nextEvent == 0 || g_eventTimes[i] < g_nextEvent)
         {
            g_nextEvent = g_eventTimes[i];
            g_nextEventTxt = g_evTitle[i];
         }
}

void RefreshFeed()
{
   if (g_lastFeed > 0 && TimeGMT() - g_lastFeed < News_RefreshMinutes * 60) return;
   g_lastFeed = TimeGMT();
   string url = "https://nfs.faireconomy.media/ff_calendar_thisweek.json";
   char data[], result[]; string rh;
   ResetLastError();
   int code = WebRequest("GET", url, "", "", 8000, data, 0, result, rh);
   if (code == 200 && ArraySize(result) > 0)
   {
      string json = CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8);
      ParseCalendar(json);
      FeedOk = true; g_feedStatus = "OK"; g_lastFeedOk = TimeGMT();
      int h = FileOpen("ff_cache.json", FILE_WRITE | FILE_TXT | FILE_ANSI);
      if (h != INVALID_HANDLE) { FileWriteString(h, json); FileClose(h); }
      LogAction("FEED_OK", StringFormat("%d High events watched", g_eventsLoaded));
   }
   else
   {
      FeedOk = false; g_feedStatus = "disk cache";
      int h = FileOpen("ff_cache.json", FILE_READ | FILE_TXT | FILE_ANSI);
      if (h != INVALID_HANDLE)
      {
         string json = ""; while (!FileIsEnding(h)) json += FileReadString(h) + "\n";
         FileClose(h);
         ParseCalendar(json);
         LogAction("CACHE_OK", StringFormat("%d High events watched from cache (WebRequest err %d)", g_eventsLoaded, GetLastError()));
      }
      else LogAction("FEED_FAIL", StringFormat("WebRequest err %d and no cache", GetLastError()));
   }
}

bool InNewsWindow(string &eventName)
{
   eventName = "";
   if (g_nextEvent == 0) return false;
   datetime now = TimeGMT();
   if (now >= g_nextEvent - News_MinutesBefore * 60 && now <= g_nextEvent + News_MinutesAfter * 60)
   {
      eventName = (g_nextEventTxt != "") ? g_nextEventTxt : "High impact";
      return true;
   }
   return false;
}
bool InNewsWindow() { string e; return InNewsWindow(e); }   // convenience overload for gate/panel checks

// News state, v2.0: TRACKING ONLY. Entering a window no longer closes anything and
// no longer touches the global AutoTrading button - it only stops NEW entries via
// the gate in OracleOnEngine, which is exactly what Oracle 2.0 does with
// "When News Filter activates -> Close = False".
//
// Why the close was removed: flattening a basket on a news window REALIZES a loss
// that the basket would usually have recovered at its shared TP. Measured
// 2026-07-23, that class of forced cut is what pushed Cerberus's avg_loss to
// -$3.58 against Oracle's -$1.78 while WINNING more often (66.5% vs 62%).
void EvaluateNewsState()
{
   string evName = "";
   bool inWindow = InNewsWindow(evName);

   if (inWindow)
   {
      g_activeEventName = evName;
      if (!g_wasInWindow) LogAction("WINDOW_ENTER", evName + " (entries blocked, open baskets left alone)");
   }
   else
   {
      if (g_wasInWindow) LogAction("WINDOW_EXIT", g_activeEventName);
      g_activeEventName = "";
   }
   g_wasInWindow = inWindow;

 // Legacy: older builds parked an "AT turned off by news" flag here. Nothing sets
 // it any more, so clear a stale one left over from a v1.x run or the button would
 // stay off forever with no rule owning it.
   if (GlobalVariableCheck(GV_GUARD))
   {
      GlobalVariableDel(GV_GUARD);
      if (!AutoTradingOn() && !GlobalVariableCheck(GV_PAUSE))
      {
         SetAutoTrading(true);
         LogAction("AUTOTRADING_ON", "clearing a stale v1.x news lock");
      }
   }
}

//==================================================================
// Guardian rules
//==================================================================
void Rule_DailyBaseline()
{
   string today = TimeToString(TimeGMT(), TIME_DATE);
   if (!GlobalVariableCheck(GV_DAYDATE) ||
       TimeToString((datetime)GlobalVariableGet(GV_DAYDATE), TIME_DATE) != today ||
       AccountBalance() > GlobalVariableGet(GV_DAYBAL) + 100.0)   // deposit detected
   {
      GlobalVariableSet(GV_DAYDATE, (double)(datetime)StringToTime(today));
      GlobalVariableSet(GV_DAYBAL, AccountBalance());
      LogAction("RESETDAY", StringFormat("Daily baseline re-anchored to $%.2f", AccountBalance()));
      g_bstopHitsToday = 0;
   }
}

void ApplyDefenseRules()
{
   if (!IsConnected() || AccountBalance() <= 0) return;
   Rule_DailyBaseline();

 // Rule E: daily loss: close everything AND turn the global
 // AutoTrading button OFF (not just the soft g_paused flag), so no EA in the
 // terminal keeps trading during the pause. RESUME re-enables both.
 // Guard `!GlobalVariableCheck(GV_PAUSE)`: do not
 // re-fire while already paused, or it re-closes and re-logs RULE_DAILY_LOSS
 // every timer/tick pass (the 5s spam seen 2026-07-21). GV_PAUSE is deleted by
 // RESUME, so the rule can arm again on the next day / after a manual resume.
   double dayLoss = GlobalVariableGet(GV_DAYBAL) - AccountEquity();
   if (DailyLoss_USD > 0 && dayLoss >= DailyLoss_USD && !GlobalVariableCheck(GV_PAUSE))
   {
      LogAction("RULE_DAILY_LOSS", StringFormat("day loss %.2f >= %.2f: closing everything and pausing", dayLoss, DailyLoss_USD));
      CloseEverything("maximum daily loss");
 // 2 = "the guardian paused this", vs 1 = "a human paused this". Every other
 // check only asks whether the GV exists, so both still mean paused; only
 // DoResetDay tells them apart (it may lift a rule E pause, never a human one).
      g_paused = true; GlobalVariableSet(GV_PAUSE, 2);
      SetAutoTrading(false);
      return;
   }

 // v2.0: rules A (adverse pips), B (margin level) and D (USD per position) were
 // REMOVED. All three closed individual positions out of a basket, which realizes
 // a loss and breaks the average the shared TP depends on - the mechanism behind
 // the -$3.58 avg_loss. Oracle 2.0 has none of them (Stop Loss 0.0, Equity
 // Protection all 0.0) and loses less per trade while winning less often.
 //
 // Rule B specifically was checked with this account's real numbers before
 // dropping it: XAUUSDm ~$4047 at 1:200 means 0.01 lot locks ~$20.24 of margin,
 // so on $1k the margin level only reaches 200% around 20 open levels / -$190
 // floating - the same depth where rule E already fires at -$200. It was a third
 // redundant cut, not a last-resort net (Exness stops out near 0-60%).
}

// v2.0: rule C (volatility circuit breaker) was REMOVED - the ATR spike, the
// N-bar window, the fixed-pips variant, the renewable pause and CloseOnVolSpike.
// It cut baskets on exactly the moves a grid is built to average through, and
// Oracle 2.0 has no equivalent. Measurement that closed the argument
// (memory: filtro-horario-sin-respaldo-datos): BASKET_STOP events cluster at
// 02-03 UTC, a band the risk table calls VERY LOW - the breaker was firing on
// volatility that had no relation to where the damage actually happened.

//==================================================================
// Session guards: open warm-up (+ display-only weekly-close warning)
//==================================================================
// Instrument class: 2=crypto, 1=metal, 0=other.
// Used to exempt crypto from the weekend pre-close (crypto trades 24/7).
int SymClass(string sym)
{
   string up = sym; StringToUpper(up);
   if (StringFind(up, "BTC") == 0 || StringFind(up, "ETH") == 0 ||
       StringFind(up, "XRP") == 0 || StringFind(up, "LTC") == 0) return 2;
   if (StringFind(up, "XAU") == 0 || StringFind(up, "XAG") == 0 ||
       StringFind(up, "GOLD") == 0 || StringFind(up, "SILVER") == 0) return 1;
   return 0;
}

// Tradable now. MT4 has no SymbolInfoSessionTrade, so MODE_TRADEALLOWED is the
// closest proxy: it goes false when the symbol is not tradable (closed / rollover
// pause), which is exactly what we need to gate on.
// Unconditional in v2.0: this is not a risk filter, it is "can we send an order at
// all". Trying to trade a closed market only earns err 132/133 spam and a 10-minute
// server backoff, so there is nothing to switch off.
bool MarketOpenNow(string sym)
{
   return (MarketInfo(sym, MODE_TRADEALLOWED) != 0);
}

//==================================================================
// Hour-risk table (DISPLAY ONLY in v2.0) + regime filter + AT toggle
//==================================================================
int HourRisk(int minUTC)   // minute of the UTC day [0,1440)
{
   static int rStart[10] = {0, 420, 480, 570, 720, 930, 1020, 1140, 1260, 1380};
   static int rRisk [10] = {0,   2,   3,   2,   3,   2,    1,    2,    1,    0};
   int r = 0;
   for (int i = 0; i < 10; i++)
      if (minUTC >= rStart[i]) r = rRisk[i];
   return r;
}

int NowMinUTC() { return TimeHour(TimeGMT()) * 60 + TimeMinute(TimeGMT()); }

// v2.0: HourBlocked is GONE - the table above is published to the panel and to
// ng_status.json and never gates an entry. The whole scheduler (UseSchedule,
// Sched1-4, per-day toggles, SchedKillAT) is gone with it: its defaults blocked
// 08:00-09:30 and 12:00-15:30, which are EXACTLY the two VERY HIGH bands of
// HourRisk - the same block applied twice - and SchedKillAT killed the terminal-
// global AutoTrading button behind a GV lock that survived restarts.

void ToggleAutoTrading()
{
   int hRoot = GetAncestor((int)ChartGetInteger(0, CHART_WINDOW_HANDLE), 2 /*GA_ROOT*/);
   PostMessageW(hRoot, WM_COMMAND, MT4_CMD_AUTOTRADING, 0);
}

// AutoTrading state helpers.
// The AutoTrading button is terminal-global; toggling it affects every EA.
bool AutoTradingOn() { return (TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) != 0); }

// TERMINAL_TRADE_ALLOWED only reflects the GLOBAL AutoTrading button. The per-EA
// "Allow live trading" checkbox (F7 -> Common) and the short window right after an
// INIT, while the terminal re-arms the expert, are visible ONLY through
// IsTradeAllowed. Sending an order without checking it is what produced the
// err 4109 one second after every restart. Logged at most once a minute so a
// genuinely unchecked box still shows up instead of failing silently.
bool TradingPermitted()
{
   if (IsTradeAllowed()) return true;
   static datetime lastNotReadyLog = 0;
   if (TimeGMT() - lastNotReadyLog >= 60)
   {
      lastNotReadyLog = TimeGMT();
      LogAction("AT_NOT_READY", "terminal does not allow this EA to trade (IsTradeAllowed false): re-init window, or 'Allow live trading' unchecked in the EA properties");
   }
   return false;
}

void SetAutoTrading(bool enable)
{
   if (AutoTradingOn() == enable) return;   // already in the desired state
   ToggleAutoTrading();
}

// Effective grid depth cap: hard cap wins; otherwise capital-proportional.
int EffMaxLevels()
{
   if (EffMaxLev() > 0) return EffMaxLev();
   if (Capital_PerLevel > 0 && Capital_Base > 0)
      return (int)MathMax(1, MathFloor(Capital_Base / Capital_PerLevel));
   return 9999;
}

// Weekend pre-close window. as far
// as the MT4 API allows. Two design notes:
// - crypto is exempted (SymClass==2): it trades through the weekend, no gap.
// - only fires for the WEEKEND close (PreCloseWeekendOnly), not the nightly
// rollover.
// API LIMIT: a full session API would ask the broker MinutesToSessionClose / IsWeekendClose (real
// session table). MT4 has no session API, so we approximate the weekend close
// as Friday at FridayCloseHourGMT. If the Exness server offset is not exactly
// GMT, this fires a few minutes off from the reference session-accurate time - the one
// spot where exact parity is impossible on MT4. Set FridayCloseHourGMT to the
// server's real Friday close (logged by LogSessions at OnInit).
// DISPLAY ONLY in v2.0. This used to flatten every basket minutes before the
// weekly close ("weekend-gap protection"); now it only reports, because that
// flatten realized whatever the basket happened to be holding at a fixed clock
// time - the single most arbitrary of all the cuts.
//
// The weekend-gap risk it addressed is REAL and is NOT handled any more: a grid
// left open over the ~49 h close can gap on Sunday's reopen. That is now a manual
// decision (send CLOSEALL before Friday's close if you want to be flat).
bool InSessionWarning()
{
   if (!Show_SessionWarning || SessionWarn_Min <= 0) return false;
   if (SymClass(g_sym) == 2) return false;                 // crypto trades 24/7, no weekly close
   if (TimeDayOfWeek(TimeGMT()) != 5) return false;        // weekly close = Friday
   datetime closeT = StringToTime(TimeToString(TimeGMT(), TIME_DATE) + StringFormat(" %02d:00", SessionClose_HourGMT));
   return (TimeGMT() >= closeT - SessionWarn_Min * 60 && TimeGMT() < closeT);
}

bool ClosedOrWarmingUp()
{
   if (!MarketOpenNow(g_sym)) { g_sawClosed = true; return true; }
   if (g_sawClosed)
   {
      g_sawClosed = false; g_openedAt = TimeGMT();
      if (OpenWarmup_Min > 0)
         LogAction("OPEN_WARMUP", StringFormat("%s: session reopened, entries vetoed %d min", g_sym, OpenWarmup_Min));
   }
   return (OpenWarmup_Min > 0 && g_openedAt > 0 && TimeGMT() - g_openedAt < OpenWarmup_Min * 60);
}

//==================================================================
// ORACLE strategy
//==================================================================
void Basket(string sym, int magic, int &n, int &dir, double &lots, double &avg, double &pl, double &last, datetime &lastTime)
{
   n = 0; dir = 0; lots = 0; avg = 0; pl = 0; last = 0; lastTime = 0;
   double sumLotPrice = 0, loPrice = 0, hiPrice = 0;
   for (int i = 0; i < OrdersTotal(); i++)
   {
      if (!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if (OrderSymbol() != sym || OrderMagicNumber() != magic || OrderType() > OP_SELL) continue;
      n++;
      dir  = (OrderType() == OP_BUY) ? 1 : -1;
      lots += OrderLots();
      sumLotPrice += OrderLots() * OrderOpenPrice();
      pl += OrderProfit() + OrderSwap() + OrderCommission();
      if (OrderOpenTime() >= lastTime) lastTime = OrderOpenTime();
 // Anchor the grid to the basket EXTREME, not the newest-by-time level: with
 // second-resolution OrderOpenTime and price rebounds, the newest level is
 // often not the extreme, which let adds stack pips apart and violate the
 // GridSize gate (measured 2026-07-20: 17/20 adds inside the gate, 21 levels
 // instead of ~4). BUY grid anchors on the basket low, SELL on the high.
      double op = OrderOpenPrice();
      if (loPrice == 0 || op < loPrice) loPrice = op;
      if (hiPrice == 0 || op > hiPrice) hiPrice = op;
   }
   if (lots > 0) avg = sumLotPrice / lots;
   if (n > 0) last = (dir > 0) ? loPrice : hiPrice;
}

// Set each order's take profit INDIVIDUALLY at its own open price + TP pips, the
// way Oracle 2.0 does (measured live 2026-07-23): every order is an independent
// scalp that closes on a TP-pip move in its own favour, so in an oscillating
// market many close for small wins instead of the whole basket waiting on the
// weighted-average TP. The server-side SL below stays BASKET-level (a backstop for
// the whole ladder, only armed when BasketStop_USD>0).
void SetBasketTP(string sym, int magic)
{
   int n, dir; double lots, avg, pl, last; datetime lt;
   Basket(sym, magic, n, dir, lots, avg, pl, last, lt);
   if (n == 0) return;
   int digits = (int)MarketInfo(sym, MODE_DIGITS);
   double point = MarketInfo(sym, MODE_POINT);

 // Server-side SL backstop, sized so the WHOLE basket losing at once
 // approximates the basket stop: distance = BasketStopUSD / (lots * $-per-
 // point), off the CURRENT average, re-anchored on every add like the TP.
 // The broker executes this itself even when our close orders get rejected
 // (measured 2026-07-20: MT4's own basket stop fired on time but the server
 // refused every close retry for ~25 min while price kept running, -$400+
 // worse than the configured -$100 stop).
   double bidNow = MarketInfo(sym, MODE_BID);
   double askNow = MarketInfo(sym, MODE_ASK);
   double minDist = MarketInfo(sym, MODE_STOPLEVEL) * point;

   double slPx = 0;
   if (BasketStop_ServerSL && EffBstop() > 0 && lots > 0)
   {
      double tickVal = MarketInfo(sym, MODE_TICKVALUE);
      double tickSize = MarketInfo(sym, MODE_TICKSIZE);
      if (tickVal > 0 && tickSize > 0)
      {
         double pxDist = (EffBstop() / lots) * (tickSize / tickVal);
         slPx = (dir > 0) ? NormalizeDouble(avg - pxDist, digits) : NormalizeDouble(avg + pxDist, digits);
 // Respect the broker's minimum stops distance from the CURRENT market
 // price, or OrderModify is rejected (err 130) and the SL never gets set.
         if (dir > 0 && slPx > bidNow - minDist) slPx = NormalizeDouble(bidNow - minDist - point, digits);
         if (dir < 0 && slPx < askNow + minDist) slPx = NormalizeDouble(askNow + minDist + point, digits);
         if (dir > 0 && slPx >= avg) slPx = 0;   // sanity: never past the average
         if (dir < 0 && slPx <= avg) slPx = 0;
      }
   }

   for (int i = 0; i < OrdersTotal(); i++)
   {
      if (!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if (OrderSymbol() != sym || OrderMagicNumber() != magic || OrderType() > OP_SELL) continue;
      // INDIVIDUAL TP: TP pips from THIS order's own open price, not the basket avg.
      double tp = NormalizeDouble(OrderOpenPrice() + dir * EffTP() * StratPip(sym), digits);
 // Staleness threshold: pip*0.1 (=0.01 on gold), not
 // point/2 (=0.0005). Prevents re-modifying the TP/SL on sub-pip drift, so
 // MT4 sends far fewer OrderModify calls (was ~20x more than needed).
      double staleTol = StratPip(sym) * 0.1;
      bool tpStale = MathAbs(OrderTakeProfit() - tp) > staleTol;
      bool slStale = (slPx > 0) && MathAbs(OrderStopLoss() - slPx) > staleTol;
      if (!tpStale && !slStale) continue;
      if (!OrderModify(OrderTicket(), OrderOpenPrice(), (slPx > 0) ? slPx : OrderStopLoss(), tp, 0))
      {
         int merr = GetLastError();
         static datetime lastModErrLog = 0;
         if (TimeGMT() - lastModErrLog > 60) { lastModErrLog = TimeGMT(); Print("Cerberus4: modify #", OrderTicket(), " err=", merr); }
      }
   }
}

// Returns true only when EVERY level of the basket was actually closed, so the
// caller can tell a real cut from an announced-but-failed one.
bool CloseBasket(string sym, int magic, string reason)
{
   bool allOk = true;
   for (int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if (!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if (OrderSymbol() != sym || OrderMagicNumber() != magic || OrderType() > OP_SELL) continue;
      if (!ClosePosition(OrderTicket(), reason)) allOk = false;
   }
   return allOk;
}

bool OpenLevel(string sym, int magic, int dir, int level)
{
   RefreshRates();
   double lot = NormalizeDouble(EffLot() * MathPow(EffFactor(), level), 2);
   double price = (dir > 0) ? MarketInfo(sym, MODE_ASK) : MarketInfo(sym, MODE_BID);
   int t = OrderSend(sym, (dir > 0) ? OP_BUY : OP_SELL, lot, price, 300, 0, 0,
                     "Cerberus4", magic, 0, (dir > 0) ? clrBlue : clrRed);
   if (t < 0)
   {
      int err = GetLastError();
      if (TimeGMT() >= g_srvBlockUntil)   // log once per backoff window, not per tick
         LogAction("ORACLE", StringFormat("%s open FAILED err=%d (engine %d level %d)", sym, err, magic, level));
 // BROKER side: market closed / trading disabled by the server. Only the
 // broker clears these, so the long backoff is right.
      if (err == 133 || err == 132 || err == 4059 || err == 4112)
      {
         g_srvBlockUntil = TimeGMT() + ServerBlock_Min * 60;
         LogAction("SRV_BLOCK", StringFormat("%s: server refused trading (err %d); pausing entries %d min", sym, err, ServerBlock_Min));
      }
 // LOCAL side: the terminal has not armed THIS EA yet. Seen ~1 s after every
 // INIT that follows the properties dialog / an account change (2026-07-20
 // 23:24:15 uninit 6, 2026-07-21 00:37:50 uninit 5) and it clears by itself
 // in seconds. It used to share the 10-min SRV_BLOCK bucket, which cost 10
 // minutes of trading after every restart. Short backoff instead.
      else if (err == 4109 || err == 4110 || err == 4111)
      {
         g_srvBlockUntil = TimeGMT() + LocalBlock_Sec;
         LogAction("AT_LOCAL_BLOCK", StringFormat("%s: terminal not allowing this EA to trade yet (err %d); retrying in %d s",
                   sym, err, LocalBlock_Sec));
      }
      return false;
   }
   return true;
}

// Direction bias: Gann HiLo Activator, EXACT match to Oracle_Bias in the original design
// build. The HiLo side persists once flipped and IS the signal on its own -
// NOT gated by the EMA (on M1 the fast HiLo and slow EMA disagree constantly;
// requiring both killed every entry, bias=0, which is what this function did
// until 2026-07-20 and is why it traded far less than the original design in the
// same market). The MA is only a tie-breaker before the HiLo has any side yet
// (very first bars after (re)start).
int SignalTF()  { return (Signal_TF > 0) ? Signal_TF : PERIOD_M1; }

// Applied price for the MA. Oracle 2.0 runs it on the OPEN, not the close: its
// input screen reads "Moving Average Price = Open price", and MT4's enum has
// PRICE_CLOSE=0 / PRICE_OPEN=1. A project note had recorded InpMaPrice=1 as
// "close", so this port filtered on a different price than Oracle for days.
int MaPrice() { return (MA_AppliedPrice == 1) ? PRICE_OPEN : PRICE_CLOSE; }

// Trend brake: true while price is more than TrendBrake_MaxDistPips from the MA(34),
// i.e. running directionally. Blocks NEW entries and adds (never closes) so Cerberus
// stops fading a runaway trend - Oracle stays quiet in exactly this case.
bool TrendBrakeBlocked(string sym, double pip)
{
   if (TrendBrake_MaxDistPips <= 0 || pip <= 0) return false;
   int method = (MA_Method == 1) ? MODE_EMA : MODE_SMA;
   double ma = iMA(sym, SignalTF(), MA_Period, 0, method, MaPrice(), 0);
   if (ma == 0) return false;
   return (MathAbs(MarketInfo(sym, MODE_BID) - ma) / pip > TrendBrake_MaxDistPips);
}

// Persist the HiLo side so a restart resumes the indicator's real state instead of
// silently falling back to the MA (see GV_HILO_SIDE). Only writes on a flip.
int g_prevHiloSide = 0;
void SetHiloSide(int side)
{
   if (side == g_prevHiloSide) return;
   g_prevHiloSide = side;
   GlobalVariableSet(GV_HILO_SIDE, side);
}

// Gann HiLo Activator. Oracle's "HILO Method = Exponential" means the high and low
// bands are EMAs, not the arithmetic means this port used - an EMA weights the
// most recent bar far more, so it flips sooner on a turn.
// iMA on PRICE_HIGH / PRICE_LOW gives exactly that band with the configured method.
int Bias()
{
   int method = (MA_Method == 1) ? MODE_EMA : MODE_SMA;
   double ma = iMA(g_sym, SignalTF(), MA_Period, 0, method, MaPrice(), 1);
   double close = iClose(g_sym, SignalTF(), 1);
   if (ma == 0 || close == 0) return 0;

   int hiloMethod = (HiLo_Method == 1) ? MODE_EMA : MODE_SMA;
   double hiAvg = iMA(g_sym, SignalTF(), HiLo_Period, 0, hiloMethod, PRICE_HIGH, 1);
   double loAvg = iMA(g_sym, SignalTF(), HiLo_Period, 0, hiloMethod, PRICE_LOW,  1);
   if (hiAvg == 0 || loAvg == 0) return 0;

   if (close > hiAvg)      SetHiloSide(1);   // raw breakout / trend side
   else if (close < loAvg) SetHiloSide(-1);
   int raw = g_prevHiloSide;
   if (raw == 0) raw = (close > ma) ? 1 : (close < ma ? -1 : 0);   // start-up: MA trend side

 // ORACLE FADES THE MARKET. The entry is the OPPOSITE of the trend/breakout side.
 // Measured live 2026-07-23 side-by-side (Oracle on account 73114915): Oracle BOUGHT
 // a falling market (@4042.6 -> 4042.2) and SOLD the rebound (@4044.0), while
 // Cerberus's old trend-following bias was BUY at the very same instant - exact
 // opposites. Adds are unaffected (they always follow the existing basket
 // direction, never Bias).
   return -raw;
}

int g_prevN[2] = {0, 0};   // per-engine level count on the previous pass (cycle tally)

void OracleOnEngine(int magic)
{
   string sym = g_sym;
   int n, dir; double lots, avg, pl, last; datetime lt;
   Basket(sym, magic, n, dir, lots, avg, pl, last, lt);

 // Basket went flat since the last pass -> one cycle completed. Book its
 // realized P/L from the freshest closes of this magic (panel tally, GVs
 // survive restarts just's counters).
   int ei = EngineIdx(magic);
   if (n == 0 && g_prevN[ei] > 0)
   {
      double cyc = 0; int left = g_prevN[ei];
      for (int h = OrdersHistoryTotal() - 1; h >= 0 && left > 0; h--)
      {
         if (!OrderSelect(h, SELECT_BY_POS, MODE_HISTORY)) continue;
         if (OrderType() > OP_SELL || OrderMagicNumber() != magic) continue;
         cyc += OrderProfit() + OrderSwap() + OrderCommission();
         left--;
      }
      GlobalVariableSet("CB4_cycles", GlobalVariableGet("CB4_cycles") + 1);
      GlobalVariableSet("CB4_realized", GlobalVariableGet("CB4_realized") + cyc);
   }
   g_prevN[ei] = n;
   double pip = StratPip(sym);
   if (pip <= 0) return;
   double bid = MarketInfo(sym, MODE_BID);

   if (n > 0) SetBasketTP(sym, magic);

   if (!IsConnected() || AccountEquity() <= 0) return;

   // HYBRID exit like Oracle: on top of each order's individual TP (set above),
   // close the WHOLE basket when its TOTAL floating equals ONE order's TP worth -
   // i.e. the average is +(TP / n) pips, NOT +TP. Measured 2026-07-24: Oracle
   // closed a 6-level basket at avg+3.3 pips and a 3-level one at avg+13.7 pips,
   // both ~one TP unit of total profit. Dividing by n is what lets a deep ladder
   // clear on a SMALL bounce (a 5-level basket needs only TP/5 = 3 pips), which is
   // exactly how Oracle keeps a lean book instead of a sunk +TP ladder that never
   // clears. Only for n>=2 (a lone order already exits on its own server-side TP).
   if (n >= 2)
   {
      double avgTP = avg + dir * (EffTP() / (double)n) * pip;
      bool avgHit = (dir > 0) ? (bid >= avgTP) : (MarketInfo(sym, MODE_ASK) <= avgTP);
      if (avgHit)
      {
         LogAction("BASKET_TP", StringFormat("%s magic %d: avg %.3f +%.1fp (TP/%d) reached, closing %d levels (net %.2f)",
                   sym, magic, avg, EffTP() / (double)n, n, n, pl));
         CloseBasket(sym, magic, "basket avg TP (TP/n)");
         return;
      }
   }

 // Basket stop BEFORE soft blocks (a blocked hour must not delay the cut)
   if (n > 0 && EffBstop() > 0 && pl <= -EffBstop())
   {
      LogAction("BASKET_STOP", StringFormat("%s magic %d: floating %.2f <= -%.2f, cutting %d levels (%.2f lots)",
                sym, magic, pl, EffBstop(), n, lots));
 // Only SPEND the stop (hit counter + cooldown) if the cut really happened.
 // Marking it on an announced-but-failed close left the basket running with
 // its stop already used up (err 136, 2026-07-21 00:26:30).
      if (!CloseBasket(sym, magic, "basket stop"))
      {
         LogAction("BASKET_STOP_FAIL", StringFormat("%s magic %d: cut incomplete, retrying next pass", sym, magic));
         return;
      }
      g_bstopHitsToday++;
      if (BasketStop_CooldownMin > 0)
         g_bstopUntil[EngineIdx(magic)] = TimeGMT() + BasketStop_CooldownMin * 60;
      return;
   }

 // Soft blocks for NEW entries/adds. v2.0 dropped the hour filter, the scheduler,
 // the rule C pause and the Friday pre-close from this gate - what is left either
 // protects the ORDER (spread, server backoff, market closed) or is the news
 // window, which Oracle also respects for entries.
   if (g_paused || InNewsWindow() || TimeGMT() < g_srvBlockUntil || ClosedOrWarmingUp()) return;

   bool spreadOK = (MaxSpread_Points <= 0) || (MarketInfo(sym, MODE_SPREAD) <= MaxSpread_Points);

   if (n == 0)
   {
      if (TimeGMT() < g_bstopUntil[EngineIdx(magic)]) return;
      if (!spreadOK) return;
      if (TrendBrakeBlocked(sym, pip)) return;   // trend brake: do not open into a runaway
      int bias = Bias();
 // One side per engine when both are on, matching Oracle 2.0 as MEASURED:
 // magic 7799 takes SELL and 9977 takes BUY (EngineSide). A lone engine
 // trades both sides, one basket at a time.
      int side = 0;
      if (Engine_A_Sell && Engine_B_Buy) side = EngineSide(magic);
      if (bias == 0 || (side != 0 && bias != side)) return;

      // NEVER HOLD BOTH SIDES. Before arming a fresh basket, close any basket the
      // OTHER engine still holds - a fade flip must leave us on ONE side only, the
      // way Oracle keeps a lean book instead of a hedged SELL+BUY dead weight that
      // never clears (measured 2026-07-24: Cerberus carried a 3-level SELL AND a
      // 2-level BUY at once, floating -$5, while Oracle held one 1-level basket).
      if (Engine_A_Sell && Engine_B_Buy)
      {
         int other = (magic == MAGIC_A) ? MAGIC_B : MAGIC_A;
         int on, od; double ol, oa, opl, olast; datetime olt;
         Basket(sym, other, on, od, ol, oa, opl, olast, olt);
         if (on > 0)
         {
            LogAction("FLIP_CLOSE", StringFormat("%s: arming %s, closing opposite engine %d (%d levels, net %.2f)",
                      sym, (bias > 0 ? "BUY" : "SELL"), other, on, opl));
            CloseBasket(sym, other, "one side only (fade flip)");
         }
      }

      // Re-arm immediately after a close, like Oracle: as long as the fade side is
      // valid, a closed basket opens the next one on the following tick. Oracle books
      // many shallow wins this way; gating new baskets on a HiLo flip (tried and
      // removed) starved the win-booking - measured 28 cycles vs Oracle's ~72.
      if (OpenLevel(sym, magic, bias, 0))
      {
         g_lastAddTime[ei] = TimeCurrent();   // throttle the first add too
         SetBasketTP(sym, magic);
      }
      return;
   }

   bool depthOK = (n < EffMaxLevels());
   double adverse = (dir < 0) ? (bid - last) : (last - bid);
   double nextLot = EffLot() * MathPow(EffFactor(), n);
 // Throttle: the timer AND ticks run the grid, so without a minimum gap a burst
 // of ticks in one second adds several levels before the fresh order is visible,
 // stacking them pips apart and violating GridSize. One add per MinSecs_BetweenAdds.
   int ei2 = EngineIdx(magic);
   bool addThrottled = (MinSecs_BetweenAdds > 0 &&
                        TimeCurrent() - g_lastAddTime[ei2] < MinSecs_BetweenAdds);
   if (spreadOK && depthOK && !addThrottled && !TrendBrakeBlocked(sym, pip) && adverse >= EffGrid() * pip && (lots + nextLot) <= MaxLot_Total)
   {
      if (OpenLevel(sym, magic, dir, n))
      {
         g_lastAddTime[ei2] = TimeCurrent();
         SetBasketTP(sym, magic);
      }
   }
}

void OracleOnAll()
{
   if (!g_oracleOn) return;
   if (Engine_A_Sell) OracleOnEngine(MAGIC_A);
   if (Engine_B_Buy) OracleOnEngine(MAGIC_B);
}

//==================================================================
// Hot overrides (SET / BSTOP commands) - persisted in GVs, survive a restart
//==================================================================
void SaveOverridesToGV()
{
   if (g_ovTP    > 0)  GlobalVariableSet(GV_OV_TP,    g_ovTP);
   if (g_ovGrid  > 0)  GlobalVariableSet(GV_OV_GRID,  g_ovGrid);
   if (g_ovLot   > 0)  GlobalVariableSet(GV_OV_LOT,   g_ovLot);
   if (g_ovFactor > 0) GlobalVariableSet(GV_OV_FACTOR, g_ovFactor);
   if (g_ovMaxLev >= 0) GlobalVariableSet(GV_OV_MAXLEV, g_ovMaxLev);
   if (g_ovBstop >= 0) GlobalVariableSet(GV_OV_BSTOP, g_ovBstop);
}

void LoadOverridesFromGV()
{
   if (GlobalVariableCheck(GV_OV_TP))     g_ovTP     = GlobalVariableGet(GV_OV_TP);
   if (GlobalVariableCheck(GV_OV_GRID))   g_ovGrid   = GlobalVariableGet(GV_OV_GRID);
   if (GlobalVariableCheck(GV_OV_LOT))    g_ovLot    = GlobalVariableGet(GV_OV_LOT);
   if (GlobalVariableCheck(GV_OV_FACTOR)) g_ovFactor = GlobalVariableGet(GV_OV_FACTOR);
   if (GlobalVariableCheck(GV_OV_MAXLEV)) g_ovMaxLev = (int)GlobalVariableGet(GV_OV_MAXLEV);
   if (GlobalVariableCheck(GV_OV_BSTOP))  g_ovBstop  = GlobalVariableGet(GV_OV_BSTOP);
}

// Re-anchor the Rule E daily baseline. Shared by the RESETDAY command and the
// panel button so both behave identically (DoResetDay).
void DoResetDay(string via)
{
   GlobalVariableSet(GV_DAYBAL, AccountBalance());
   GlobalVariableSet(GV_DAYDATE, (double)(datetime)StringToTime(TimeToString(TimeGMT(), TIME_DATE)));
   LogAction("RESETDAY", StringFormat("Daily baseline re-anchored to $%.2f%s", AccountBalance(), via));
 // Re-anchoring the day while rule E holds the pause used to leave the EA silent:
 // baseline fresh, AutoTrading still off, and nothing in the log to explain it
 // (there is no error - it is paused on purpose). So RESETDAY now finishes the job
 // it implies and lifts a GUARDIAN pause. A HUMAN pause is left alone, but says so.
   if (!GlobalVariableCheck(GV_PAUSE)) return;
   if ((int)GlobalVariableGet(GV_PAUSE) == 1)
   {
      LogAction("WARNING", "baseline re-anchored but a MANUAL pause is still active: press RESUME (or send the RESUME command) to trade again");
      return;
   }
   g_paused = false;
   GlobalVariableDel(GV_PAUSE);
   GlobalVariableDel(GV_GUARD);
   SetAutoTrading(true);
   LogAction("RESUME", "rule E pause lifted by RESETDAY");
}

string ConfigLine()
{
   return StringFormat("%s TP=%.0f GRID=%.0f LOT=%.2f FACTOR=%.2f MAXLEV=%d BSTOP=%.2f ENTRY=FADE",
                       g_sym, EffTP(), EffGrid(), EffLot(), EffFactor(), EffMaxLev(), EffBstop());
}

//==================================================================
// Command channel
//==================================================================
void ProcessCommand()
{
   if (!FileIsExist(COMMAND_FILE)) return;
   int h = FileOpen(COMMAND_FILE, FILE_READ | FILE_TXT | FILE_ANSI);
   if (h == INVALID_HANDLE) return;
   string raw = FileReadString(h);
   FileClose(h);
   FileDelete(COMMAND_FILE);
   StringTrimLeft(raw); StringTrimRight(raw);
   if (raw == "") return;
   string cmd = raw; StringToUpper(cmd);
   LogAction("COMMAND", raw);

   if (cmd == "PAUSE")        { CloseEverything("PAUSE command"); g_paused = true; GlobalVariableSet(GV_PAUSE, 1); SetAutoTrading(false); }
   else if (cmd == "RESUME")  { g_paused = false; GlobalVariableDel(GV_PAUSE); GlobalVariableDel(GV_GUARD); SetAutoTrading(true); LogAction("RESUME", "manual pause lifted"); }
   else if (cmd == "CLOSEALL") CloseEverything("CLOSEALL command");
   else if (cmd == "RESETDAY") DoResetDay("");
   else if (cmd == "ORACLE_ON")  { g_oracleOn = true;  GlobalVariableSet(GV_ORACLE_ON, 1); LogAction("ORACLE", "engine ON"); }
   else if (cmd == "ORACLE_OFF") { g_oracleOn = false; GlobalVariableSet(GV_ORACLE_ON, 0); LogAction("ORACLE", "engine OFF"); }
   else if (cmd == "CONFIG")     LogAction("CONFIG", ConfigLine());
   else if (cmd == "PANELDUMP")  PanelDump();
   else if (StringFind(cmd, "BSTOP") == 0)
   {
      string parts[]; int np = StringSplit(raw, ' ', parts);
      if (np >= 2)
      {
         g_ovBstop = MathMax(0, StringToDouble(parts[1]));
         SaveOverridesToGV();
         LogAction("BSTOP", (g_ovBstop > 0) ? StringFormat("basket stop = %.0f USD by command", g_ovBstop) : "basket stop OFF by command");
      }
      else LogAction("WARNING", "syntax: BSTOP <usd> (0 = off)");
   }
   else if (cmd == "AT_ON" || cmd == "AT_OFF")
   {
      bool at = (TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) != 0);
      if ((cmd == "AT_ON" && !at) || (cmd == "AT_OFF" && at)) ToggleAutoTrading();
      LogAction("AUTOTRADING", cmd);
   }
   else if (StringFind(cmd, "TEST=") == 0)
   {
      int mins = (int)StringToInteger(StringSubstr(raw, 5));
      if (mins > 0)
      {
         g_nextEvent = TimeGMT() + mins * 60;
         g_nextEventTxt = "USD TEST CMD";
         LogAction("TEST", StringFormat("fake USD event injected %d min ahead", mins));
      }
   }
   else if (StringFind(cmd, "SET") == 0)
   {
      string parts[]; int np = StringSplit(raw, ' ', parts);
      for (int i = 1; i < np; i++)
      {
         string kvp[]; if (StringSplit(parts[i], '=', kvp) != 2) continue;
         string key = kvp[0]; StringToUpper(key);
         double val = StringToDouble(kvp[1]);
 //: assign the value as-is (no val>0 filter) and warn
 // on unknown keys, so SET behaves identically on both platforms.
         if      (key == "TP")     g_ovTP     = val;
         else if (key == "GRID")   g_ovGrid   = val;
         else if (key == "LOT")    g_ovLot    = val;
         else if (key == "FACTOR") g_ovFactor = val;
         else if (key == "MAXLEV") g_ovMaxLev = (int)val;
         else LogAction("WARNING", "SET: unknown key " + key);
      }
      SaveOverridesToGV();
      SetBasketTP(g_sym, MAGIC_A); SetBasketTP(g_sym, MAGIC_B);   // re-anchor live baskets
      LogAction("SET", ConfigLine());
   }
   else LogAction("WARNING", "unknown command: " + raw);
}

//==================================================================
// Closed-history tally - MQL4 order-history equivalent of the original design's
// TallyClosedHistory: same fields (closed/wins/losses/realized/closedToday/
// avgWin/avgLoss), same "win if p>=0" rule, same "today" cutoff at 00:00 GMT.
// MT4 has no deal ticket model, so this walks OrdersHistoryTotal filtered to
// our two magics on the traded symbol instead of HistoryDealGetTicket.
//==================================================================
double g_peakEquity = 0;

void TallyClosedHistory(int &closed, int &wins, int &losses, double &realized,
                        int &closedToday, double &sumWin, double &sumLoss)
{
   closed = wins = losses = closedToday = 0;
   realized = sumWin = sumLoss = 0;
   datetime nowG = TimeGMT();
   datetime dayStart = nowG - (nowG % 86400);   // 00:00 GMT today
   for (int h = OrdersHistoryTotal() - 1; h >= 0; h--)
   {
      if (!OrderSelect(h, SELECT_BY_POS, MODE_HISTORY)) continue;
      if (OrderType() > OP_SELL || !IsOurMagic(OrderMagicNumber())) continue;
      double p = OrderProfit() + OrderSwap() + OrderCommission();
      closed++; realized += p;
      if (p >= 0) { wins++;   sumWin  += p; }
      else        { losses++; sumLoss += p; }
      if (OrderCloseTime() >= dayStart) closedToday++;
   }
}

//==================================================================
// Status JSON
//==================================================================
datetime g_lastStatus = 0;
void WriteStatus()
{
   if (TimeGMT() - g_lastStatus < 30) return;
   g_lastStatus = TimeGMT();
   string s = "{";
   s += "\"ea\":\"Cerberus4\",\"version\":\"2.00\",";
   s += "\"gmt\":\"" + TimeToString(TimeGMT(), TIME_DATE | TIME_SECONDS) + "\",";
 // AT_OFF must outrank RUNNING. The terminal remembers the global AutoTrading
 // button across restarts, so a button left off by a PREVIOUS build silently
 // gates the whole strategy - and this field used to keep publishing "RUNNING"
 // while nothing could trade (seen 2026-07-23: 13 min of zero orders with the
 // JSON claiming RUNNING; only the panel's "AutoTrading: OFF" gave it away).
   s += "\"status\":\"" + (!AutoTradingOn() ? "AT_OFF" :
                          (g_paused ? "PAUSED_MANUAL" :
                          (InNewsWindow() ? "PAUSED_NEWS" : "RUNNING"))) + "\",";
   s += StringFormat("\"autotrading\":%s,", AutoTradingOn() ? "true" : "false");
 // Hour band and weekly-close warning are DISPLAY ONLY: published so the panel and
 // the compare tooling can show them, explicitly flagged as non-blocking.
   s += StringFormat("\"hour_risk\":{\"band\":\"%s\",\"level\":%d,\"blocks\":false},",
                     RiskName(HourRisk(NowMinUTC())), HourRisk(NowMinUTC()));
   s += StringFormat("\"session_warning\":%s,", InSessionWarning() ? "true" : "false");
   s += StringFormat("\"config\":{\"symbol\":\"%s\",\"tp\":%.0f,\"grid\":%.0f,\"lot\":%.2f,\"maxlev\":%d},", g_sym, EffTP(), EffGrid(), EffLot(), EffMaxLev());
   {
      double _pip = StratPip(g_sym);
      double _ma  = iMA(g_sym, SignalTF(), MA_Period, 0, (MA_Method == 1) ? MODE_EMA : MODE_SMA, MaPrice(), 0);
      double _dist = (_ma > 0 && _pip > 0) ? MathAbs(MarketInfo(g_sym, MODE_BID) - _ma) / _pip : 0;
      bool _brk = (TrendBrake_MaxDistPips > 0 && _dist > TrendBrake_MaxDistPips);
      s += StringFormat("\"trend_brake\":{\"max_pips\":%d,\"dist_pips\":%.0f,\"braking\":%s},",
                        TrendBrake_MaxDistPips, _dist, _brk ? "true" : "false");
   }
   s += StringFormat("\"basket_stop\":{\"usd\":%.0f,\"hits_today\":%d},", EffBstop(), g_bstopHitsToday);
   s += "\"feed\":\"" + (FeedOk ? "OK" : "disk cache") + "\",";
   s += StringFormat("\"events_loaded\":%d,", g_eventsLoaded);
   double eq = AccountEquity();
   s += StringFormat("\"balance\":%.2f,\"equity\":%.2f,", AccountBalance(), eq);
   double flo = 0;
   for (int i = 0; i < OrdersTotal(); i++)
      if (OrderSelect(i, SELECT_BY_POS, MODE_TRADES) && OrderType() <= OP_SELL)
         flo += OrderProfit() + OrderSwap() + OrderCommission();
   s += StringFormat("\"positions_pl\":%.2f,", flo);

   int tCl, tWn, tLs, tClToday; double tRlz, tSumWin, tSumLoss;
   TallyClosedHistory(tCl, tWn, tLs, tRlz, tClToday, tSumWin, tSumLoss);
   double winRate = (tCl > 0) ? (100.0 * tWn / tCl) : 0.0;
   double avgWin  = (tWn > 0) ? (tSumWin / tWn) : 0.0;
   double avgLoss = (tLs > 0) ? (tSumLoss / tLs) : 0.0;
   if (eq > g_peakEquity) g_peakEquity = eq;
   double ddMoney = (g_peakEquity > 0) ? (g_peakEquity - eq) : 0.0;
   double ddPct   = (g_peakEquity > 0) ? (ddMoney / g_peakEquity * 100.0) : 0.0;
   s += StringFormat("\"closed_trades\":%d,\"wins\":%d,\"losses\":%d,\"win_rate_pct\":%.1f,",
                    tCl, tWn, tLs, winRate);
   s += StringFormat("\"realized_pl\":%.2f,\"closed_today\":%d,\"avg_win\":%.2f,\"avg_loss\":%.2f,",
                    tRlz, tClToday, avgWin, avgLoss);
   s += StringFormat("\"peak_equity\":%.2f,\"dd_money\":%.2f,\"dd_pct\":%.2f,", g_peakEquity, ddMoney, ddPct);
   s += "\"heads\":{\"oracle\":\"" + (g_oracleOn ? "ON" : "OFF") + "\",\"baskets\":[";
   int magics[2]; magics[0] = MAGIC_A; magics[1] = MAGIC_B;
   bool first = true;
   for (int m = 0; m < 2; m++)
   {
      int n, dir; double lots, avg, pl, last; datetime lt;
      Basket(g_sym, magics[m], n, dir, lots, avg, pl, last, lt);
      if (n == 0) continue;
      if (!first) s += ",";
      first = false;
      s += StringFormat("{\"symbol\":\"%s\",\"engine\":%d,\"steps\":%d,\"dir\":\"%s\",\"lots\":%.2f,\"avg\":%.5f,\"pl\":%.2f}",
                        g_sym, magics[m], n, dir > 0 ? "BUY" : "SELL", lots, avg, pl);
   }
   s += "]}}";
   int h = FileOpen(STATUS_FILE, FILE_WRITE | FILE_TXT | FILE_ANSI);
   if (h == INVALID_HANDLE) return;
   FileWriteString(h, s);
   FileClose(h);
}

//==================================================================
// Panel (CB_ prefix) — EXACT transcription of the original design's panel:
// same constants, colors, wording and layout, line by line.
//==================================================================
#define PANEL_X     10
#define PANEL_Y     20
#define PANEL_W     480
#define PANEL_LINES 40
#define LINE_H      16
#define PANEL_CHARS ((PANEL_W - 20) / 8)

void PanelButton(string name, int x, int y, int w, string text, color bgcolor)
{
   ObjectCreate(0, name, OBJ_BUTTON, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, w);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, 24);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 8);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, bgcolor);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clrWhite);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
}

void PanelButtonsRefresh()
{
   ObjectSetInteger(0, "CB_BTN_CLOSEALL", OBJPROP_STATE, false);
   ObjectSetInteger(0, "CB_BTN_RESETDAY", OBJPROP_STATE, false);
   ObjectSetInteger(0, "CB_BTN_RESUME", OBJPROP_STATE, false);
}

void PanelCreate()
{
   string bg = "CB_BG";
   ObjectCreate(0, bg, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, bg, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, bg, OBJPROP_XDISTANCE, PANEL_X - 5);
   ObjectSetInteger(0, bg, OBJPROP_YDISTANCE, PANEL_Y - 5);
   ObjectSetInteger(0, bg, OBJPROP_XSIZE, PANEL_W);
   ObjectSetInteger(0, bg, OBJPROP_YSIZE, PANEL_LINES * LINE_H + 101);
   ObjectSetInteger(0, bg, OBJPROP_BGCOLOR, C'20,24,32');
   ObjectSetInteger(0, bg, OBJPROP_COLOR, C'70,80,100');
   ObjectSetInteger(0, bg, OBJPROP_BACK, false);
   ObjectSetInteger(0, bg, OBJPROP_SELECTABLE, false);

   for (int i = 0; i < PANEL_LINES; i++)
   {
      string name = "CB_L" + IntegerToString(i);
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_XDISTANCE, PANEL_X);
      ObjectSetInteger(0, name, OBJPROP_YDISTANCE, PANEL_Y + i * LINE_H);
      ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 8);
      ObjectSetString(0, name, OBJPROP_FONT, "Consolas");
      ObjectSetInteger(0, name, OBJPROP_COLOR, clrGainsboro);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetString(0, name, OBJPROP_TEXT, " ");
   }

   int by1  = PANEL_Y + PANEL_LINES * LINE_H + 5;
   int third = (PANEL_W - 14 - 8) / 3;  // three buttons, two 4px gaps
   PanelButton("CB_BTN_CLOSEALL", PANEL_X, by1, third, "CLOSE ALL", C'150,110,30');
   PanelButton("CB_BTN_RESETDAY", PANEL_X + third + 4, by1, third, "RESET DAY", C'30,110,110');
   PanelButton("CB_BTN_RESUME", PANEL_X + 2 * (third + 4), by1, third, "RESUME", C'30,110,50');
   PanelButtonsRefresh();
}

void SetLine(int i, string text, color clr = clrGainsboro)
{
   if (i >= PANEL_LINES) return;
   string name = "CB_L" + IntegerToString(i);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
}

string FmtCountdown(int secs)
{
   if (secs < 0) secs = 0;
   return StringFormat("%dh %02dm", secs / 3600, (secs % 3600) / 60);
}

string PanelFit(string s)
{
   if (StringLen(s) > PANEL_CHARS) return StringSubstr(s, 0, PANEL_CHARS - 1) + "~";
   return s;
}

string RiskName(int r)
{
   if (r >= 3) return "VERY HIGH";
   if (r == 2) return "MEDIUM";   //
   if (r == 1) return "LOW";
   return "VERY LOW";
}

int MinutesToRiskChange()
{
   int now = NowMinUTC(), cur = HourRisk(now);
   for (int add = 1; add <= 1440; add++)
      if (HourRisk((now + add) % 1440) != cur) return add;
   return 0;
}

void PanelUpdate()
{
   datetime nowG = TimeGMT();
   int line = 0;

   bool manual = g_paused;
   bool inWin = InNewsWindow();
   string evName = g_nextEventTxt;

   color cDim  = C'130,140,155';
   color cUp   = C'80,200,120';
   color cDown = C'230,90,90';
   color cWarn = C'240,180,60';

 // --- Guardian state
   if (manual)           SetLine(line++, "# CERBERUS: MANUAL PAUSE", clrOrange);
   else if (inWin)       SetLine(line++, PanelFit("# CERBERUS: NEWS - no new entries: " + evName), clrTomato);
   else                  SetLine(line++, "# CERBERUS: RUNNING", clrLightGreen);

   bool at = (TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) != 0);
   SetLine(line++, StringFormat("AutoTrading: %s   Feed: %s%s",
           at ? "ON" : "OFF", g_feedStatus,
           g_lastFeedOk > 0 ? " (" + FmtCountdown((int)(nowG - g_lastFeedOk)) + ")" : ""),
           at ? clrLightGreen : clrTomato);

 // --- Hour window (gold risk table, Colombia = UTC-5)
   {
      int hm = NowMinUTC();
      int hr = HourRisk(hm);
      int colMin = (hm + 1140) % 1440;
      int chg = MinutesToRiskChange();
      string tag = " (info only)";   // v2.0: the band never blocks an entry
      SetLine(line++, StringFormat("Window %02d:%02d COL (%02d:%02d UTC): %s%s %s",
              colMin / 60, colMin % 60, hm / 60, hm % 60, RiskName(hr), tag,
              StringFormat("(%dh%02dm)", chg / 60, chg % 60)),
              hr >= 3 ? clrTomato : hr == 2 ? C'240,180,60' : clrLightGreen);
   }
   SetLine(line++, "---------------------------------------------------------");

 // --- Next news event
   int nextIdx = -1;
   for (int i = 0; i < g_eventsLoaded; i++)
      if (g_eventTimes[i] > nowG && (nextIdx == -1 || g_eventTimes[i] < g_eventTimes[nextIdx]))
         nextIdx = i;
   if (nextIdx >= 0)
   {
      int toEvent = (int)(g_eventTimes[nextIdx] - nowG);
      int toPause = toEvent - News_MinutesBefore * 60;
      SetLine(line++, PanelFit("NEXT: " + g_evTitle[nextIdx]), clrKhaki);
      SetLine(line++, StringFormat("  in %s (pause in %s)", FmtCountdown(toEvent), FmtCountdown(toPause)), clrKhaki);
   }
   else
   {
      SetLine(line++, "NEXT: (none on the calendar)", clrGray);
   }
   SetLine(line++, "---------------------------------------------------------");

 // --- ORACLE: header + 1-2 lines per engine basket
   {
      SetLine(line++, StringFormat("ORACLE %s%d PERIOD_M%d [%s] TP%.0f grid%.0f lot%.2f x%.1f  eng %s%s",
              (MA_Method == 1) ? "EMA" : "SMA", MA_Period, (Signal_TF > 0) ? Signal_TF : 1,
              g_oracleOn ? "ON" : "OFF", EffTP(), EffGrid(), EffLot(), EffFactor(),
              Engine_A_Sell ? "A" : "-", Engine_B_Buy ? "B" : "-"),
              g_oracleOn ? clrLightGreen : cDim);

      double exposure = 0;
      double pip = StratPip(g_sym);
      double sbid = MarketInfo(g_sym, MODE_BID);

      // Trend brake state - so the freeze is visible on screen
      {
         double mab = iMA(g_sym, SignalTF(), MA_Period, 0, (MA_Method == 1) ? MODE_EMA : MODE_SMA, MaPrice(), 0);
         double distp = (mab > 0 && pip > 0) ? MathAbs(sbid - mab) / pip : 0;
         bool braking = (TrendBrake_MaxDistPips > 0 && distp > TrendBrake_MaxDistPips);
         if (TrendBrake_MaxDistPips <= 0)
            SetLine(line++, "TREND BRAKE: off", cDim);
         else
            SetLine(line++, StringFormat("TREND BRAKE: %.0fp from MA / %dp  %s", distp, TrendBrake_MaxDistPips,
                    braking ? ">> BRAKING: no new / no adds" : "clear"),
                    braking ? clrTomato : clrLightGreen);
      }

      int engines[2]; engines[0] = MAGIC_A; engines[1] = MAGIC_B;
      for (int e = 0; e < 2; e++)
      {
         int n, dir; double totLots, avg, pl, lastLevel; datetime lt;
         Basket(g_sym, engines[e], n, dir, totLots, avg, pl, lastLevel, lt);
         exposure += totLots;
         if (n == 0)
         {
            int bias = Bias();
            int mySide = (Engine_A_Sell && Engine_B_Buy) ? EngineSide(engines[e]) : 0;
            string waiting = (mySide != 0 && bias != mySide) ? "  waiting" : "";
            SetLine(line++, StringFormat("%-8s e%d(%s) no basket  bias %s%s", g_sym, e,
                    mySide > 0 ? "BUY" : mySide < 0 ? "SELL" : "both",
                    bias > 0 ? "BUY" : bias < 0 ? "SELL" : "-", waiting),
                    bias > 0 ? cUp : bias < 0 ? cDown : cDim);
         }
         else
         {
            double tpPx = (dir > 0) ? avg + EffTP() * pip : avg - EffTP() * pip;
            SetLine(line++, StringFormat("%-8s e%d %s grid %d  %.2f lots  $%+.2f", g_sym, e,
                    (dir > 0) ? "BUY " : "SELL", n, totLots, pl),
                    (pl >= 0) ? cUp : cWarn);
            SetLine(line++, StringFormat("  TP at %.0fp | avg %.3f",
                    (pip > 0) ? MathAbs(tpPx - sbid) / pip : 0, avg), cDim);
         }
      }

      SetLine(line++, StringFormat("baskets closed %d | realized $%+.2f | exp %.2f lots",
              (int)GlobalVariableGet("CB4_cycles"), GlobalVariableGet("CB4_realized"), exposure), cDim);
   }
   SetLine(line++, "---------------------------------------------------------");

 // --- Last closed trades
   SetLine(line++, "LAST TRADES:", clrSilver);
   int shownH = 0, dayN = 0;
   datetime day0 = iTime(Symbol(), PERIOD_D1, 0);
   for (int h = OrdersHistoryTotal() - 1; h >= 0; h--)
   {
      if (!OrderSelect(h, SELECT_BY_POS, MODE_HISTORY)) continue;
      if (OrderType() > OP_SELL) continue;
      datetime closeT = OrderCloseTime();
      if (closeT == 0) continue;
      double hpl = OrderProfit() + OrderSwap() + OrderCommission();
      if (closeT >= day0) dayN++;
      if (shownH < 5)
      {
         SetLine(line++, StringFormat("  %s %-7s %s %.2f  $%+.2f",
                 TimeToString(closeT, TIME_MINUTES), StringSubstr(OrderSymbol(), 0, 7),
                 OrderType() == OP_BUY ? "BUY " : "SELL", OrderLots(), hpl),
                 hpl >= 0 ? clrLightGreen : clrTomato);
         shownH++;
      }
      else if (closeT < day0) break;
   }
   if (shownH == 0) SetLine(line++, "  (no closed trades)", clrGray);
   SetLine(line++, "---------------------------------------------------------");

 // Day P/L MEASURED LIKE RULE E: equity vs baseline (RESETDAY re-anchors).
   double dayBase = GlobalVariableCheck(GV_DAYBAL) ? GlobalVariableGet(GV_DAYBAL) : AccountBalance();
   double dayEq = AccountEquity() - dayBase;
   SetLine(line++, StringFormat("DAY P/L (since reset): $%+.2f  |  %d trades today", dayEq, dayN),
           dayEq >= 0 ? clrLightGreen : clrTomato);
   SetLine(line++, StringFormat("Brakes: day -%.0f | basket %s%s", DailyLoss_USD,
           EffBstop() > 0 ? StringFormat("-%.0f", EffBstop()) : "OFF",
           InSessionWarning() ? "  | WEEKLY CLOSE SOON (not flattening)" : ""), cDim);

 // --- Account. Margin level is INFORMATIONAL in v2.0: rule B was removed, so
 // nothing acts on it (colour turns amber under 200% purely as a heads-up).
   double ml = (AccountMargin() > 0) ? AccountEquity() / AccountMargin() * 100.0 : 999999;
   color mlClr = clrLightGreen;
   if (ml < 200.0) mlClr = cWarn;
   SetLine(line++, StringFormat("Equity: %.2f  Free: %.2f  Margin: %s",
           AccountEquity(), AccountFreeMargin(),
           ml >= 999999 ? "-" : StringFormat("%.0f%%", ml)), mlClr);

 // --- Last action
   SetLine(line++, PanelFit("Last action: " + g_lastAction), clrSilver);

   for (int blank = line; blank < PANEL_LINES; blank++) SetLine(blank, " ");
   PanelFitTo(line);
   ChartRedraw();
}

void PanelFitTo(int used)
{
   int by1  = PANEL_Y + used * LINE_H + 6;
   int third = (PANEL_W - 14 - 8) / 3;  // three buttons, two 4px gaps
   ObjectSetInteger(0, "CB_BG", OBJPROP_YSIZE, used * LINE_H + 45);
   ObjectSetInteger(0, "CB_BTN_CLOSEALL", OBJPROP_XDISTANCE, PANEL_X);
   ObjectSetInteger(0, "CB_BTN_CLOSEALL", OBJPROP_YDISTANCE, by1);
   ObjectSetInteger(0, "CB_BTN_CLOSEALL", OBJPROP_XSIZE, third);
   ObjectSetInteger(0, "CB_BTN_RESETDAY", OBJPROP_XDISTANCE, PANEL_X + third + 4);
   ObjectSetInteger(0, "CB_BTN_RESETDAY", OBJPROP_YDISTANCE, by1);
   ObjectSetInteger(0, "CB_BTN_RESETDAY", OBJPROP_XSIZE, third);
   ObjectSetInteger(0, "CB_BTN_RESUME", OBJPROP_XDISTANCE, PANEL_X + 2 * (third + 4));
   ObjectSetInteger(0, "CB_BTN_RESUME", OBJPROP_YDISTANCE, by1);
   ObjectSetInteger(0, "CB_BTN_RESUME", OBJPROP_XSIZE, third);
}

// PANELDUMP command: write every panel line to panel_dump.txt so the clone can
// be diffed against the original design layout without a screenshot.
void PanelDump()
{
   int h = FileOpen("panel_dump.txt", FILE_WRITE | FILE_TXT | FILE_ANSI);
   if (h == INVALID_HANDLE) return;
   for (int i = 0; i < PANEL_LINES; i++)
   {
      string txt = ObjectGetString(0, "CB_L" + IntegerToString(i), OBJPROP_TEXT);
      if (StringLen(txt) > 0 && txt != " ") FileWriteString(h, txt + "\r\n");
   }
   FileClose(h);
   LogAction("PANELDUMP", "panel_dump.txt written");
}

void PanelDelete()
{
   ObjectDelete(0, "CB_BG");
   for (int i = 0; i < PANEL_LINES; i++)
      ObjectDelete(0, "CB_L" + IntegerToString(i));
   ObjectDelete(0, "CB_BTN_CLOSEALL");
   ObjectDelete(0, "CB_BTN_RESETDAY");
   ObjectDelete(0, "CB_BTN_RESUME");
}

//==================================================================
// Lifecycle
//==================================================================
int OnInit()
{
   string syms = Symbol_Traded;
   string list[]; int nl = StringSplit(syms, ',', list);
   g_sym = (nl > 0) ? list[0] : Symbol();
   if (g_sym == "") g_sym = Symbol();
   SymbolSelect(g_sym, true);

   g_paused = (GlobalVariableCheck(GV_PAUSE) && GlobalVariableGet(GV_PAUSE) > 0);
   g_oracleOn = !(GlobalVariableCheck(GV_ORACLE_ON) && GlobalVariableGet(GV_ORACLE_ON) == 0);
   g_bstopUntil[0] = 0; g_bstopUntil[1] = 0;
   g_peakEquity = AccountEquity();   // seed drawdown baseline
   LoadOverridesFromGV();
 // Restore the HiLo side. Without this the stateful indicator restarted neutral
 // on every OnInit and the bias silently fell through to the MA until the first
 // band cross - a different regime after each terminal restart, invisible in the log.
   if (GlobalVariableCheck(GV_HILO_SIDE)) g_prevHiloSide = (int)GlobalVariableGet(GV_HILO_SIDE);

   if (StringLen(News_TestMinutes) > 0)
   {
      int tmins = (int)StringToInteger(News_TestMinutes);
      if (tmins > 0) { g_nextEvent = TimeGMT() + tmins * 60; g_nextEventTxt = "USD TEST INPUT"; }
   }

   PanelCreate();
   EventSetTimer(5);
   LogAction("INIT", StringFormat("Cerberus4 v2.00 on [%s] (%s%d/%s + HILO%d/%s tf%d, effective %s, engines %s%s = A:SELL B:BUY, hiloSide %d, re-arm immediate)",
             g_sym, (MA_Method == 1) ? "EMA" : "SMA", MA_Period,
             (MaPrice() == PRICE_OPEN) ? "open" : "close", HiLo_Period,
             (HiLo_Method == 1) ? "EMA" : "SMA",
             (Signal_TF > 0) ? Signal_TF : 1, ConfigLine(),
             Engine_A_Sell ? "A" : "-", Engine_B_Buy ? "B" : "-", g_prevHiloSide));
   LogAction("GUARD", StringFormat("v2.0 nets: dailyLoss=%.0f basketStop=%.0f | rules A/B/C/D, news-close, pre-close flatten and scheduler REMOVED; hour band + weekly close are display only",
             DailyLoss_USD, EffBstop()));
   RefreshFeed();
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   PanelDelete();
   Comment("");
   LogAction("DEINIT", StringFormat("uninit reason %d", reason));
}

void OnTimer()
{
   ProcessCommand();
   RefreshFeed();
   EvaluateNewsState();          // v2.0: tracking only - never closes, never touches AT
   ApplyDefenseRules();          // v2.0: rule E only
 // Say it out loud when the global button is what is stopping us. Silence here
 // is indistinguishable from "the market gave no signal" and cost 13 minutes of
 // a soak on 2026-07-23. Throttled to once a minute; not logged while a pause
 // owns the button on purpose (manual / rule E), which already has its own line.
   if (!AutoTradingOn() && !g_paused)
   {
      static datetime lastAtOffLog = 0;
      if (TimeGMT() - lastAtOffLog >= 60)
      {
         lastAtOffLog = TimeGMT();
         LogAction("AT_OFF", "global AutoTrading button is OFF - the strategy is idle. Send AT_ON (the terminal remembers this button across restarts).");
      }
   }
 // With AutoTrading off (manual pause, rule E) the strategy does not run.
   if (AutoTradingOn() && TradingPermitted() && !g_paused) OracleOnAll();
   WriteStatus();
   PanelUpdate();   // timer-driven, so it never blanks in a quote pause
}

void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   if (id != CHARTEVENT_OBJECT_CLICK) return;
   if (sparam == "CB_BTN_CLOSEALL")
   {
      PanelButtonsRefresh();
      LogAction("COMMAND", "CLOSE ALL (panel button)");
      CloseEverything("panel CLOSE ALL");
   }
   else if (sparam == "CB_BTN_RESETDAY")
   {
      PanelButtonsRefresh();
      DoResetDay(" (panel button)");
   }
   else if (sparam == "CB_BTN_RESUME")
   {
      PanelButtonsRefresh();
      g_paused = false;
      GlobalVariableDel(GV_PAUSE);
      GlobalVariableDel(GV_GUARD);
      SetAutoTrading(true);
      LogAction("RESUME", "manual pause lifted (panel button)");
   }
}

void OnTick()
{
 // fast path: news state (tracking only), then manage basket TPs and the basket
 // stop tick-by-tick.
   EvaluateNewsState();
   if (AutoTradingOn() && TradingPermitted() && !g_paused && g_oracleOn)
   {
      if (Engine_A_Sell) OracleOnEngine(MAGIC_A);
      if (Engine_B_Buy) OracleOnEngine(MAGIC_B);
   }
}
