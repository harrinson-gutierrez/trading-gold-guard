//+------------------------------------------------------------------+
//| Cerberus.mq4 - MQL4 port of Cerberus (guardian + ORACLE)         |
//|                                                                  |
//| Functional homolog of src-mt5/Cerberus.mq5 for MetaTrader 4.     |
//| Heads:                                                           |
//|  GUARDIAN: news windows (ForexFactory JSON with disk cache),     |
//|    volatility circuit breaker (rule C, per symbol), rules        |
//|    A (adverse pips) / B (margin) / D (USD per position) /        |
//|    E (daily loss -> close all + pause until RESUME), command     |
//|    channel ng_command.txt, status ng_status.json, CSV log.       |
//|  ORACLE (magics 7799/9977): EMA34 + HILO(3) on M1, additive      |
//|    grid, shared basket TP re-anchored to the weighted average,   |
//|    per-basket USD stop with cooldown. With BOTH engines on,      |
//|    A opens only BUY signals and B only SELL (one ladder per      |
//|    side, like the original Oracle 2.0); with one engine on it    |
//|    trades both sides, one basket at a time.                      |
//|                                                                  |
//| Pip scale for the strategy: 1 pip = Point*10 (XAUUSDm: $0.01).   |
//| The guardian's rule A uses PipSizeOverride (XAUUSDm: 0.1).       |
//| Requires hedging-style MT4 account and the WebRequest URL        |
//| https://nfs.faireconomy.media whitelisted (Options->Experts).    |
//+------------------------------------------------------------------+
#property copyright "Harrinson Gutierrez"
#property version   "1.15"
#property strict

#import "user32.dll"
   int GetAncestor(int hWnd, int gaFlags);
   int PostMessageW(int hWnd, int Msg, int wParam, int lParam);
#import
#define WM_COMMAND 0x0111
#define MT4_CMD_AUTOTRADING 33020

//==================================================================
// Inputs (names mirror the MT5 build where the feature exists)
//==================================================================
// Full input parity with src-mt5/Cerberus.mq5. Defaults mirror the PRODUCTION
// values (the Exness .chr), so a fresh attach behaves like the live MT5 build.
input string PairsToWatch        = "XAUUSDm"; // guardian watches these (CSV)
input int    MinutesBefore       = 30;     // news window: minutes before High event
input int    MinutesAfter        = 30;     // news window: minutes after
input int    FeedRefreshMinutes  = 60;     // calendar refresh period
input bool   ClosePendingOrders  = true;   // guardian closes also delete pending orders
input string TestEventMinutes    = "";     // TEST: inject a fake USD event N minutes ahead (or use TEST=N command)
input string LogFileName         = "Cerberus_log.csv";
input double MaxAdversePips      = 300.0;  // rule A: close a position this many pips against
input double RuleA_xATR          = 15.0;   // rule A: ATR-relative variant - threshold is max(MaxAdversePips, N x ATR) (0 = fixed pips only)
input double PipSizeOverride     = 0.1;    // guardian pip (XAUUSDm 3 digits => 0.1)
input double MinMarginLevelPct   = 200.0;  // rule B
input double MaxLossPerTradeUSD  = 60.0;   // rule D
input double MaxDailyLossUSD     = 200.0;  // rule E: close everything + pause until RESUME
input double VolSpikeATRmult     = 5.0;    // rule C: M1 candle > N x ATR(20)
input double VolSpikePips        = 0.0;    // rule C: absolute variant - candle > N pips (0 = off)
input bool   UseHourFilter       = true;   // hour-risk filter: block entries when HourRisk >= HourBlockRisk
input int    HourBlockRisk       = 3;      // 3 = only VERY HIGH bands (08:00-09:30, 12:00-15:30 UTC)
input bool   UseSchedule         = false;  // scheduler: block NEW entries inside the windows below (soft)
input bool   SchedKillAT         = false;  // HARD mode: entering a window closes ALL orders and turns global AutoTrading OFF
input string Sched1Start         = "08:00"; // window 1 start (UTC "HH:MM"; start==end disables)
input string Sched1End           = "09:30";
input string Sched2Start         = "12:00";
input string Sched2End           = "15:30";
input string Sched3Start         = "";
input string Sched3End           = "";
input string Sched4Start         = "";
input string Sched4End           = "";
input bool   SchedSunday         = true;   // allow new entries on this UTC day
input bool   SchedMonday         = true;
input bool   SchedTuesday        = true;
input bool   SchedWednesday      = true;
input bool   SchedThursday       = true;
input bool   SchedFriday         = true;
input bool   SchedSaturday       = true;
input int    VolWindowM1Bars     = 5;      // rule C: window bars
input double VolWindowATRmult    = 8.0;    // rule C: window range > N x ATR
input int    VolATRPeriod        = 20;
input int    VolPauseMinutes     = 3;      // rule C pause (renewable)
input bool   CloseOnVolSpike     = false;  // rule C also closes that symbol's baskets
input int    SrvBlockBackoffMin  = 10;     // BROKER-rejection backoff (market closed / trading disabled by the server)
input int    LocalBlockBackoffSec = 10;    // LOCAL-rejection backoff (err 4109/4110/4111: the terminal has not armed this EA yet)
input bool   UseSessionFilter    = true;   // Friday pre-close flatten
input int    PreCloseCloseMin    = 5;      // flatten window before Friday close
input bool   PreCloseWeekendOnly = true;   // true = flatten only before the WEEKEND close; false = before every daily close
input int    WeekendGapHours     = 6;      // gap-classification threshold (kept for set compatibility with MT5)
input int    FridayCloseHourGMT  = 21;     // gold/FX weekly close hour (GMT)
input int    Oracle_OpenWarmupMin = 15;    // veto entries N min after a session (re)open

input string Oracle_Symbols      = "XAUUSDm"; // ONE traded symbol (first CSV entry)
input int    Oracle_TF           = 1;      // signal timeframe in minutes (1 = M1, like the MT5 build)
input bool   Oracle_EngineA      = true;   // engine A (magic 7799): BUY side when both on
input bool   Oracle_EngineB      = true;   // engine B (magic 9977): SELL side when both on
input double Oracle_FixedLot     = 0.01;
input int    Oracle_TakeProfit   = 20;     // strategy pips (Point*10)
input int    Oracle_GridSize     = 50;     // strategy pips between levels
input double Oracle_GridFactor   = 1.0;    // additive grid (1.0 = constant lot)
input int    Oracle_MinSecsBetweenAdds = 2; // min seconds between grid adds of the same engine (the timer AND ticks run the grid; a tick burst could add several levels in one second before the fresh order shows, stacking them and violating GridSize). 0 = off.
input double Oracle_MaxLot       = 99.0;
input int    Oracle_MaPeriod     = 34;     // MA confirm filter period
input int    Oracle_MaMethod     = 1;      // 1 = EMA, otherwise SMA
input int    Oracle_HILOPeriod   = 3;      // Gann HiLo period
input bool   Oracle_HILOInvert   = false;  // invert the HiLo side
input int    Oracle_MaxSpread    = 240;    // points; 0 = off
input int    Oracle_MaxGridLevels = 0;     // hard depth cap (0 = use the proportional cap below)
input double Oracle_BaseCapital   = 1000;  // declared capital for the proportional depth cap
input double Oracle_DollarsPerLevel = 180; // 1 grid level per N dollars of BaseCapital (0 = no proportional cap)
input bool   Oracle_NewBasketNeedsEMA = false; // a NEW basket also needs the EMA to agree with the HiLo side (adds are never gated). Hot-switchable: EMAGATE ON|OFF
input double Oracle_BasketStopUSD = 0;     // cut a basket at -N USD floating (0 = off)
input int    Oracle_BasketStopCooldownMin = 30;
input bool   Oracle_UseRegimeFilter = false; // veto entries/adds against a strong H1 trend (soft)
input int    Oracle_RegimeADX      = 27;   // ADX(14) H1 above this = strong trend
input double Oracle_RegimeATRDist  = 3.0;  // price further than N x ATR(14) H1 from EMA200 H1 also blocks (0 = ADX only)
input bool   Oracle_UseServerSL     = true; // also arm a server-side SL per position, sized so the WHOLE basket losing at once approximates Oracle_BasketStopUSD. Broker executes it even if our close orders get rejected. No-op when Oracle_BasketStopUSD<=0.

//==================================================================
// Globals
//==================================================================
#define MAGIC_A 7799
#define MAGIC_B 9977
#define GV_PAUSE     "NG_ManualPause"
#define GV_GUARD     "NG_DisabledByGuard"   // news turned AT off (separate from scheduler's g_schedHardLock so they don't fight over the button, like MT5)
#define GV_DAYDATE   "NG_DayDate"
#define GV_DAYBAL    "NG_DayStartBal"
#define GV_OV_TP     "CB4_ovTP"
#define GV_OV_GRID   "CB4_ovGrid"
#define GV_OV_LOT    "CB4_ovLot"
#define GV_OV_FACTOR "CB4_ovFactor"
#define GV_OV_MAXLEV "CB4_ovMaxLev"
#define GV_OV_BSTOP  "CB4_ovBstop"
#define GV_OV_EMAGATE "CB4_ovEmaGate"
#define GV_ORACLE_ON "CB4_OracleOn"
#define PRESETS_FILE "symbol_presets.txt"
#define STATUS_FILE  "ng_status.json"
#define COMMAND_FILE "ng_command.txt"

string   g_watch[];              // guardian watch list
string   g_sym = "";             // traded symbol
bool     g_oracleOn = true;
bool     g_paused = false;       // manual / rule E pause
datetime g_volPauseUntil = 0;    // rule C pause (traded symbol)
datetime g_srvBlockUntil = 0;    // server-rejection backoff
datetime g_bstopUntil[2];        // per-engine basket-stop cooldown
datetime g_lastAddTime[2];       // GMT of the last level opened per engine (add throttle)
datetime g_openedAt = 0;         // last closed->open transition (warm-up)
bool     g_sawClosed = false;
datetime g_lastM1Bar = 0;        // last M1 bar the ATR spike/window rule was evaluated on (rule C runs once per CLOSED bar, like MT5)
bool     g_wasInWindow = false;  // news: were we inside a news window on the previous pass
string   g_activeEventName = ""; // news: name of the event currently pausing us
int      g_bstopHitsToday = 0;
datetime g_lastFeed = 0;
datetime g_lastFeedOk = 0;       // last SUCCESSFUL feed (panel "Feed: OK (age)")
datetime g_nextEvent = 0;        // nearest watched High event (0 = none)
string   g_nextEventTxt = "";
string   g_evTitle[64];          // event titles (panel NEXT line, like MT5)
string   g_feedStatus = "-";
double   g_ovTP = -1, g_ovGrid = -1, g_ovLot = -1, g_ovFactor = -1, g_ovBstop = -1;
int      g_ovEmaGate = -1;   // effective NewBasketNeedsEMA (-1 => use input, 0 off, 1 on)
int      g_ovMaxLev = -1;

double EffTP()     { return (g_ovTP    > 0) ? g_ovTP    : Oracle_TakeProfit; }
double EffGrid()   { return (g_ovGrid  > 0) ? g_ovGrid  : Oracle_GridSize; }
double EffLot()    { return (g_ovLot   > 0) ? g_ovLot   : Oracle_FixedLot; }
double EffFactor() { return (g_ovFactor > 0) ? g_ovFactor : Oracle_GridFactor; }
int    EffMaxLev() { return (g_ovMaxLev >= 0) ? g_ovMaxLev : Oracle_MaxGridLevels; }
double EffBstop()  { return (g_ovBstop >= 0) ? g_ovBstop : Oracle_BasketStopUSD; }
bool   EmaGateOn() { return (g_ovEmaGate >= 0) ? (g_ovEmaGate > 0) : Oracle_NewBasketNeedsEMA; }

//==================================================================
// Utilities
//==================================================================
string g_lastAction = "-";
void LogAction(string action, string detail)
{
   if (action != "INIT" && action != "DEINIT") g_lastAction = detail;
   int h = FileOpen(LogFileName, FILE_READ | FILE_WRITE | FILE_TXT | FILE_ANSI);
   if (h == INVALID_HANDLE) { Print("LOG FAIL ", action, " | ", detail); return; }
   FileSeek(h, 0, SEEK_END);
   FileWriteString(h, TimeToString(TimeGMT(), TIME_DATE | TIME_SECONDS) + ";" + action + ";" + detail + "\r\n");
   FileClose(h);
   Print("Cerberus4: ", action, " | ", detail);
}

// Strategy pip, homologated to MT5's Oracle_Pip: 10 points for 3/5/6-digit
// symbols (gold, most FX, crypto crosses), 1 point otherwise. On XAUUSDm (3
// digits) this is point*10, unchanged; it only differs on 2/4-digit symbols,
// where the old always-x10 gave TP/GridSize 10x off after a SYMBOL/PRESET switch.
double StratPip(string sym)
{
   double pt = MarketInfo(sym, MODE_POINT);
   int    dg = (int)MarketInfo(sym, MODE_DIGITS);
   return (dg == 3 || dg == 5 || dg == 6) ? pt * 10.0 : pt;
}
double GuardPip(string sym) { return (PipSizeOverride > 0) ? PipSizeOverride : StratPip(sym); }

bool IsOurMagic(int m) { return (m == MAGIC_A || m == MAGIC_B); }
int  EngineIdx(int m)  { return (m == MAGIC_A) ? 0 : 1; }

// Close one ticket. Homologated to MT5's CloseOnePosition: up to 3 attempts with
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
         g_srvBlockUntil = TimeGMT() + SrvBlockBackoffMin * 60;
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
      if (StringFind(obj, "\"country\":\"USD\"") < 0 && StringFind(obj, "\"currency\":\"USD\"") < 0) continue;
      int dp = StringFind(obj, "\"date\":\"");
      if (dp < 0) continue;
      int dq = StringFind(obj, "\"", dp + 8);
      datetime t = ParseFFDate(StringSubstr(obj, dp + 8, dq - dp - 8));
      if (t <= 0) continue;
      string title = "";
      int tp = StringFind(obj, "\"title\":\"");
      if (tp >= 0) { int tq = StringFind(obj, "\"", tp + 9); title = StringSubstr(obj, tp + 9, tq - tp - 9); }
      g_evTitle[g_eventsLoaded] = title;
      g_eventTimes[g_eventsLoaded++] = t;
   }
   // nearest upcoming
   for (int i = 0; i < g_eventsLoaded; i++)
      if (g_eventTimes[i] > TimeGMT() - MinutesAfter * 60)
         if (g_nextEvent == 0 || g_eventTimes[i] < g_nextEvent) g_nextEvent = g_eventTimes[i];
}

void RefreshFeed()
{
   if (g_lastFeed > 0 && TimeGMT() - g_lastFeed < FeedRefreshMinutes * 60) return;
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
   if (now >= g_nextEvent - MinutesBefore * 60 && now <= g_nextEvent + MinutesAfter * 60)
   {
      eventName = (g_nextEventTxt != "") ? g_nextEventTxt : "USD High";
      return true;
   }
   return false;
}
bool InNewsWindow() { string e; return InNewsWindow(e); }   // convenience overload for gate/panel checks

// News guardian, homologated to MT5's EvaluateNewsState (2026-07-21). On ENTERING
// a news window: close every order and turn the GLOBAL AutoTrading button OFF
// (so no EA trades through the event); on LEAVING: turn it back ON. Uses GV_GUARD
// (separate from the scheduler's g_schedHardLock and from GV_PAUSE) so news and
// the scheduler never fight over the button. Runs every tick/timer. Before this,
// MT4 only soft-blocked new entries during news and left open baskets running.
void EvaluateNewsState()
{
   bool manualPause = GlobalVariableCheck(GV_PAUSE);
   string evName = "";
   bool inWindow = InNewsWindow(evName);

   if (manualPause)
   {
      // Manual pause / rule E owns the button: keep AT off, do not fight it.
      if (AutoTradingOn()) SetAutoTrading(false);
      g_wasInWindow = inWindow;
      return;
   }

   if (inWindow)
   {
      g_activeEventName = evName;
      if (!g_wasInWindow) LogAction("WINDOW_ENTER", evName);
      if (AutoTradingOn())
      {
         CloseEverything("news: " + evName);
         SetAutoTrading(false);
         GlobalVariableSet(GV_GUARD, 1);
         LogAction("AUTOTRADING_OFF", evName);
      }
   }
   else
   {
      if (g_wasInWindow) LogAction("WINDOW_EXIT", g_activeEventName);
      g_activeEventName = "";
      if (GlobalVariableCheck(GV_GUARD) && !AutoTradingOn())
      {
         SetAutoTrading(true);
         GlobalVariableDel(GV_GUARD);
         LogAction("AUTOTRADING_ON", "window over");
      }
      else if (GlobalVariableCheck(GV_GUARD) && AutoTradingOn())
      {
         GlobalVariableDel(GV_GUARD);   // button already on (user re-enabled) - just clear our flag
      }
   }
   g_wasInWindow = inWindow;
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

   // Rule E: daily loss. Homologated to MT5: close everything AND turn the global
   // AutoTrading button OFF (not just the soft g_paused flag), so no EA in the
   // terminal keeps trading during the pause. RESUME re-enables both.
   // Guard `!GlobalVariableCheck(GV_PAUSE)` homologated to MT5 (line 1478): do not
   // re-fire while already paused, or it re-closes and re-logs RULE_DAILY_LOSS
   // every timer/tick pass (the 5s spam seen 2026-07-21). GV_PAUSE is deleted by
   // RESUME, so the rule can arm again on the next day / after a manual resume.
   double dayLoss = GlobalVariableGet(GV_DAYBAL) - AccountEquity();
   if (MaxDailyLossUSD > 0 && dayLoss >= MaxDailyLossUSD && !GlobalVariableCheck(GV_PAUSE))
   {
      LogAction("RULE_DAILY_LOSS", StringFormat("day loss %.2f >= %.2f: closing everything and pausing", dayLoss, MaxDailyLossUSD));
      CloseEverything("maximum daily loss");
      // 2 = "the guardian paused this", vs 1 = "a human paused this". Every other
      // check only asks whether the GV exists, so both still mean paused; only
      // DoResetDay tells them apart (it may lift a rule E pause, never a human one).
      g_paused = true; GlobalVariableSet(GV_PAUSE, 2);
      SetAutoTrading(false);
      return;
   }

   // Rule B: margin protection. Homologated to MT5 - close the WORST position
   // repeatedly (up to 10 per pass) until the margin level recovers, instead of
   // closing only one per timer pass. Recomputes the margin level each iteration.
   if (MinMarginLevelPct > 0)
   {
      for (int iter = 0; iter < 10; iter++)
      {
         double margin = AccountMargin();
         if (margin <= 0) break;
         double ml = AccountEquity() / margin * 100.0;
         if (ml >= MinMarginLevelPct) break;

         int worst = -1; double worstPl = 0;
         for (int i = OrdersTotal() - 1; i >= 0; i--)
            if (OrderSelect(i, SELECT_BY_POS, MODE_TRADES) && OrderType() <= OP_SELL)
            {
               double p = OrderProfit() + OrderSwap() + OrderCommission();
               if (worst < 0 || p < worstPl) { worstPl = p; worst = OrderTicket(); }
            }
         if (worst < 0) break;
         LogAction("RULE_MARGIN", StringFormat("margin level %.1f%% < %.1f%%: closing worst #%d (%.2f)", ml, MinMarginLevelPct, worst, worstPl));
         if (!ClosePosition(worst, "margin level")) break;
      }
   }

   // Rules A + D per position. Homologated to MT5: the WHOLE of rule A (fixed
   // pips AND the ATR-relative variant) is gated on MaxAdversePips>0, so setting
   // MaxAdversePips=0 disables rule A entirely - matching MT5, where a 0 turns the
   // rule off. (With the production default 300 this changes nothing.)
   for (int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if (!OrderSelect(i, SELECT_BY_POS, MODE_TRADES) || OrderType() > OP_SELL) continue;
      string sym = OrderSymbol();
      double gpip = GuardPip(sym);
      double bid = MarketInfo(sym, MODE_BID), ask = MarketInfo(sym, MODE_ASK);
      double adverse = (OrderType() == OP_BUY) ? (OrderOpenPrice() - bid) / gpip
                                               : (ask - OrderOpenPrice()) / gpip;
      double pl = OrderProfit() + OrderSwap() + OrderCommission();
      if (MaxAdversePips > 0)
      {
         double ruleAThr = MaxAdversePips;
         if (RuleA_xATR > 0)
         {
            double atrA = iATR(sym, PERIOD_M1, VolATRPeriod, 1);
            if (atrA > 0) ruleAThr = MathMax(ruleAThr, RuleA_xATR * atrA / gpip);
         }
         if (adverse >= ruleAThr)
         {
            LogAction("RULE_PIPS", StringFormat("#%d %s %.1f pips against (limit %.0f)", OrderTicket(), sym, adverse, ruleAThr));
            ClosePosition(OrderTicket(), "adverse pips");
            continue;
         }
      }
      if (MaxLossPerTradeUSD > 0 && pl <= -MaxLossPerTradeUSD)
      {
         LogAction("RULE_LOSS_USD", StringFormat("#%d %s P/L %.2f (limit -%.2f)", OrderTicket(), sym, pl, MaxLossPerTradeUSD));
         ClosePosition(OrderTicket(), "USD loss per position");
      }
   }

}

// Rule C: volatility circuit breaker on the traded symbol. HOMOLOGATED TO MT5
// (2026-07-21): the ATR spike and the N-bar window are evaluated ONCE PER CLOSED
// M1 BAR (shift 1), guarded by g_lastM1Bar - exactly like MT5's CheckVolatilitySpike,
// which has `if (barT == g_lastM1Bar[i]) continue`. Only the FIXED-pips variant
// (VolSpikePips) runs intrabar on the forming candle, in CheckSpikePipsLive below,
// matching MT5's CheckSpikePipsLive (shift 0 and 1). Before this, MT4 evaluated
// the ATR spike on the forming candle (shift 0) every tick, cutting up to ~60s
// earlier than MT5 on the same move - the divergence this fix removes.
void CloseSymbolBasketsC()   // helper: rule C flush of the traded symbol's Oracle positions
{
   for (int i = OrdersTotal() - 1; i >= 0; i--)
      if (OrderSelect(i, SELECT_BY_POS, MODE_TRADES) && OrderSymbol() == g_sym && IsOurMagic(OrderMagicNumber()))
         ClosePosition(OrderTicket(), "Oracle rule C spike");
}

void CheckVolatilitySpike()
{
   if (VolSpikeATRmult <= 0 && VolWindowATRmult <= 0) return;
   // Once per CLOSED M1 bar only (like MT5). The forming-candle ATR spike is NOT
   // evaluated here - that intrabar path is fixed-pips only (CheckSpikePipsLive).
   datetime barT = iTime(g_sym, PERIOD_M1, 1);
   if (barT == 0 || barT == g_lastM1Bar) return;
   g_lastM1Bar = barT;

   double atr = iATR(g_sym, PERIOD_M1, VolATRPeriod, 1);
   if (atr <= 0) return;
   double spip = StratPip(g_sym);

   double candle = iHigh(g_sym, PERIOD_M1, 1) - iLow(g_sym, PERIOD_M1, 1);
   if (VolSpikeATRmult > 0 && candle >= VolSpikeATRmult * atr && TimeGMT() > g_volPauseUntil)
   {
      g_volPauseUntil = TimeGMT() + VolPauseMinutes * 60;
      LogAction("VOL_SPIKE", StringFormat("%s M1 candle = %.1f pips (ATR %.1f), pause %d min",
                g_sym, candle / spip, atr / spip, VolPauseMinutes));
      if (CloseOnVolSpike) CloseSymbolBasketsC();
      return;
   }

   if (VolWindowATRmult > 0 && VolWindowM1Bars > 1)
   {
      int hiBar = iHighest(g_sym, PERIOD_M1, MODE_HIGH, VolWindowM1Bars, 1);
      int loBar = iLowest (g_sym, PERIOD_M1, MODE_LOW,  VolWindowM1Bars, 1);
      if (hiBar < 0 || loBar < 0) return;
      double window = iHigh(g_sym, PERIOD_M1, hiBar) - iLow(g_sym, PERIOD_M1, loBar);
      if (window >= VolWindowATRmult * atr && TimeGMT() > g_volPauseUntil)
      {
         g_volPauseUntil = TimeGMT() + VolPauseMinutes * 60;
         LogAction("VOL_SPIKE", StringFormat("%s %d-bar window = %.1f pips (ATR %.1f), pause %d min",
                   g_sym, VolWindowM1Bars, window / spip, atr / spip, VolPauseMinutes));
         if (CloseOnVolSpike) CloseSymbolBasketsC();
      }
   }
}

// Fixed-pips spike, evaluated INTRABAR (forming candle shift 0 and last closed
// shift 1) every tick - the only rule-C path MT5 runs live. No-op unless
// VolSpikePips>0 (default 0). Mirrors MT5's CheckSpikePipsLive exactly.
void CheckSpikePipsLive()
{
   if (VolSpikePips <= 0) return;
   double spip = StratPip(g_sym);
   if (spip <= 0) return;
   for (int shift = 0; shift <= 1; shift++)
   {
      if (iTime(g_sym, PERIOD_M1, shift) == 0) continue;
      double candle = iHigh(g_sym, PERIOD_M1, shift) - iLow(g_sym, PERIOD_M1, shift);
      if (candle / spip < VolSpikePips) continue;
      if (TimeGMT() > g_volPauseUntil)
      {
         g_volPauseUntil = TimeGMT() + VolPauseMinutes * 60;
         LogAction("VOL_SPIKE", StringFormat("%s M1 candle %s of %.1f pips (fixed limit %.0f), pause %d min",
                   g_sym, shift == 0 ? "IN PROGRESS" : "closed", candle / spip, VolSpikePips, VolPauseMinutes));
         if (CloseOnVolSpike) CloseSymbolBasketsC();
      }
      return;
   }
}

//==================================================================
// Session guards: Friday pre-close flatten + open warm-up
//==================================================================
// Instrument class, 1:1 with MT5's SymClass: 2=crypto, 1=metal, 0=other.
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

// Tradable now. Homologated to MT5's MarketOpen: respects UseSessionFilter.
// API LIMIT: MT4 has no SymbolInfoSessionTrade, so we cannot read the broker's
// exact session table like MT5 does. MODE_TRADEALLOWED is the closest proxy the
// MT4 API exposes - it goes false when the symbol is not tradable (closed /
// rollover pause), which is what the session check gates on. Not bit-identical
// to MT5's InTradingSession, but the same effect for the traded symbol.
bool MarketOpenNow(string sym)
{
   if (!UseSessionFilter) return true;   // filter off -> never block (like MT5)
   return (MarketInfo(sym, MODE_TRADEALLOWED) != 0);
}

//==================================================================
// Hour-risk filter + scheduler + regime filter + AT toggle
// (1:1 homologs of the MT5 build)
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

bool HourBlocked() { return UseHourFilter && HourRisk(NowMinUTC()) >= HourBlockRisk; }

int SchedParseHHMM(string s)
{
   StringTrimLeft(s); StringTrimRight(s);
   if (StringLen(s) == 0) return -1;
   int colon = StringFind(s, ":");
   if (colon <= 0) return -1;
   int h = (int)StringToInteger(StringSubstr(s, 0, colon));
   int m = (int)StringToInteger(StringSubstr(s, colon + 1));
   if (h < 0 || h > 23 || m < 0 || m > 59) return -1;
   return h * 60 + m;
}

bool SchedDayAllowed()
{
   switch (TimeDayOfWeek(TimeGMT()))
   {
      case 0: return SchedSunday;    case 1: return SchedMonday;
      case 2: return SchedTuesday;   case 3: return SchedWednesday;
      case 4: return SchedThursday;  case 5: return SchedFriday;
      default: return SchedSaturday;
   }
}

bool g_schedHardLock = false;   // HARD mode: AT was turned off by us

void ToggleAutoTrading()
{
   int hRoot = GetAncestor((int)ChartGetInteger(0, CHART_WINDOW_HANDLE), 2 /*GA_ROOT*/);
   PostMessageW(hRoot, WM_COMMAND, MT4_CMD_AUTOTRADING, 0);
}

// AutoTrading state helpers, homologated to MT5 (AutoTradingOn / SetAutoTrading).
// The AutoTrading button is terminal-global; toggling it affects every EA.
bool AutoTradingOn() { return (TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) != 0); }

// TERMINAL_TRADE_ALLOWED only reflects the GLOBAL AutoTrading button. The per-EA
// "Allow live trading" checkbox (F7 -> Common) and the short window right after an
// INIT, while the terminal re-arms the expert, are visible ONLY through
// IsTradeAllowed(). Sending an order without checking it is what produced the
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

bool SchedInWindow()
{
   if (!SchedDayAllowed()) return true;   // whole UTC day vetoed
   int now = NowMinUTC();
   string ws[4]; string we[4];
   ws[0] = Sched1Start; we[0] = Sched1End; ws[1] = Sched2Start; we[1] = Sched2End;
   ws[2] = Sched3Start; we[2] = Sched3End; ws[3] = Sched4Start; we[3] = Sched4End;
   for (int i = 0; i < 4; i++)
   {
      int a = SchedParseHHMM(ws[i]), b = SchedParseHHMM(we[i]);
      if (a < 0 || b < 0 || a == b) continue;
      if (a < b) { if (now >= a && now < b) return true; }
      else       { if (now >= a || now < b) return true; }   // wraps midnight
   }
   return false;
}

bool SchedBlocked()
{
   if (!UseSchedule) return false;
   bool inWin = SchedInWindow();
   if (SchedKillAT)
   {
      bool at = (TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) != 0);
      if (inWin && !g_schedHardLock)
      {
         LogAction("SCHED_HARD", "window entered: closing everything and turning AutoTrading OFF");
         CloseEverything("scheduler HARD window");
         if (at) ToggleAutoTrading();
         g_schedHardLock = true;
      }
      else if (!inWin && g_schedHardLock)
      {
         LogAction("SCHED_HARD", "window left: turning AutoTrading back ON");
         if (!at) ToggleAutoTrading();
         g_schedHardLock = false;
      }
   }
   return inWin;
}

// Regime filter: veto entries/adds against a strong H1 trend (soft, fail-open).
bool RegimeBlocked(int dir)
{
   if (!Oracle_UseRegimeFilter || dir == 0) return false;
   double adx = iADX(g_sym, PERIOD_H1, 14, PRICE_CLOSE, MODE_MAIN, 1);
   if (adx > Oracle_RegimeADX)
   {
      double dip = iADX(g_sym, PERIOD_H1, 14, PRICE_CLOSE, MODE_PLUSDI, 1);
      double dim = iADX(g_sym, PERIOD_H1, 14, PRICE_CLOSE, MODE_MINUSDI, 1);
      if (dir > 0 && dim > dip) return true;   // buying against a strong downtrend
      if (dir < 0 && dip > dim) return true;   // selling against a strong uptrend
   }
   if (Oracle_RegimeATRDist > 0)
   {
      double ema = iMA(g_sym, PERIOD_H1, 200, 0, MODE_EMA, PRICE_CLOSE, 1);
      double atr = iATR(g_sym, PERIOD_H1, 14, 1);
      double px  = MarketInfo(g_sym, MODE_BID);   // live bid, homologated to MT5 (was iClose H1 close): MT5 reads the live bid so the regime veto reacts intrabar, not only at the H1 close
      if (ema > 0 && atr > 0)
      {
         if (dir > 0 && px < ema - Oracle_RegimeATRDist * atr) return true;   // buying deep under EMA200
         if (dir < 0 && px > ema + Oracle_RegimeATRDist * atr) return true;   // selling far above EMA200
      }
   }
   return false;
}

// Effective grid depth cap: hard cap wins; otherwise capital-proportional.
int EffMaxLevels()
{
   if (EffMaxLev() > 0) return EffMaxLev();
   if (Oracle_DollarsPerLevel > 0 && Oracle_BaseCapital > 0)
      return (int)MathMax(1, MathFloor(Oracle_BaseCapital / Oracle_DollarsPerLevel));
   return 9999;
}

// Weekend pre-close window. Homologated to MT5's Oracle_PreCloseBlocked as far
// as the MT4 API allows. Two things brought to parity with MT5:
//   - crypto is exempted (SymClass==2): it trades through the weekend, no gap.
//   - only fires for the WEEKEND close (PreCloseWeekendOnly), not the nightly
//     rollover, like MT5.
// API LIMIT: MT5 asks the broker MinutesToSessionClose / IsWeekendClose (real
// session table). MT4 has no session API, so we approximate the weekend close
// as Friday at FridayCloseHourGMT. If the Exness server offset is not exactly
// GMT, this fires a few minutes off from MT5's session-accurate time - the one
// spot where exact parity is impossible on MT4. Set FridayCloseHourGMT to the
// server's real Friday close (logged by LogSessions at OnInit).
bool InFridayPreClose()
{
   if (!UseSessionFilter || PreCloseCloseMin <= 0) return false;
   if (SymClass(g_sym) == 2) return false;                                    // crypto never pre-closes (like MT5)
   if (PreCloseWeekendOnly && TimeDayOfWeek(TimeGMT()) != 5) return false;    // weekend close = Friday
   datetime closeT = StringToTime(TimeToString(TimeGMT(), TIME_DATE) + StringFormat(" %02d:00", FridayCloseHourGMT));
   return (TimeGMT() >= closeT - PreCloseCloseMin * 60 && TimeGMT() < closeT);
}

void PreCloseFlatten()
{
   if (!InFridayPreClose()) return;
   bool any = false;
   for (int i = OrdersTotal() - 1; i >= 0; i--)
      if (OrderSelect(i, SELECT_BY_POS, MODE_TRADES) && OrderSymbol() == g_sym && IsOurMagic(OrderMagicNumber()))
      { any = true; ClosePosition(OrderTicket(), "pre-close weekend-gap protection"); }
   if (any) LogAction("PRECLOSE_FLATTEN", g_sym + " weekly close soon: flattening baskets (weekend-gap protection)");
}

bool ClosedOrWarmingUp()
{
   if (!MarketOpenNow(g_sym)) { g_sawClosed = true; return true; }
   if (g_sawClosed)
   {
      g_sawClosed = false; g_openedAt = TimeGMT();
      if (Oracle_OpenWarmupMin > 0)
         LogAction("OPEN_WARMUP", StringFormat("%s: session reopened, entries vetoed %d min", g_sym, Oracle_OpenWarmupMin));
   }
   return (Oracle_OpenWarmupMin > 0 && g_openedAt > 0 && TimeGMT() - g_openedAt < Oracle_OpenWarmupMin * 60);
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

void SetBasketTP(string sym, int magic)
{
   int n, dir; double lots, avg, pl, last; datetime lt;
   Basket(sym, magic, n, dir, lots, avg, pl, last, lt);
   if (n == 0) return;
   int digits = (int)MarketInfo(sym, MODE_DIGITS);
   double point = MarketInfo(sym, MODE_POINT);
   double tp = NormalizeDouble(avg + dir * EffTP() * StratPip(sym), digits);

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
   if (Oracle_UseServerSL && EffBstop() > 0 && lots > 0)
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
      // Staleness threshold homologated to MT5: pip*0.1 (=0.01 on gold), not
      // point/2 (=0.0005). Prevents re-modifying the TP/SL on sub-pip drift, so
      // MT4 sends far fewer OrderModify calls (was ~20x more than MT5).
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
         g_srvBlockUntil = TimeGMT() + SrvBlockBackoffMin * 60;
         LogAction("SRV_BLOCK", StringFormat("%s: server refused trading (err %d); pausing entries %d min", sym, err, SrvBlockBackoffMin));
      }
      // LOCAL side: the terminal has not armed THIS EA yet. Seen ~1 s after every
      // INIT that follows the properties dialog / an account change (2026-07-20
      // 23:24:15 uninit 6, 2026-07-21 00:37:50 uninit 5) and it clears by itself
      // in seconds. It used to share the 10-min SRV_BLOCK bucket, which cost 10
      // minutes of trading after every restart. Short backoff instead.
      else if (err == 4109 || err == 4110 || err == 4111)
      {
         g_srvBlockUntil = TimeGMT() + LocalBlockBackoffSec;
         LogAction("AT_LOCAL_BLOCK", StringFormat("%s: terminal not allowing this EA to trade yet (err %d); retrying in %d s",
                   sym, err, LocalBlockBackoffSec));
      }
      return false;
   }
   return true;
}

// Direction bias: Gann HiLo Activator, EXACT match to Oracle_Bias() in the MT5
// build. The HiLo side persists once flipped and IS the signal on its own -
// NOT gated by the EMA (on M1 the fast HiLo and slow EMA disagree constantly;
// requiring both killed every entry, bias=0, which is what this function did
// until 2026-07-20 and is why it traded far less than the MT5 build in the
// same market). The EMA is only a tie-breaker before the HiLo has any side yet
// (very first bars after (re)start).
// Price vs EMA side (+1 above / -1 below / 0 flat-or-no-data). Only used by the
// EMAGATE experiment: it decides whether a NEW basket may arm, never an add.
int EmaSide()
{
   int tf = (Oracle_TF > 0) ? Oracle_TF : PERIOD_M1;
   int method = (Oracle_MaMethod == 1) ? MODE_EMA : MODE_SMA;
   double ma = iMA(g_sym, tf, Oracle_MaPeriod, 0, method, PRICE_CLOSE, 1);
   double close = iClose(g_sym, tf, 1);
   if (ma == 0 || close == 0) return 0;
   return (close > ma) ? 1 : (close < ma ? -1 : 0);
}

int g_prevHiloSide = 0;
int Bias()
{
   int tf = (Oracle_TF > 0) ? Oracle_TF : PERIOD_M1;
   int method = (Oracle_MaMethod == 1) ? MODE_EMA : MODE_SMA;
   double ma = iMA(g_sym, tf, Oracle_MaPeriod, 0, method, PRICE_CLOSE, 1);
   double close = iClose(g_sym, tf, 1);
   if (ma == 0 || close == 0) return 0;
   double sumHi = 0, sumLo = 0;
   for (int k = 1; k <= Oracle_HILOPeriod; k++)
   {
      sumHi += iHigh(g_sym, tf, k);
      sumLo += iLow (g_sym, tf, k);
   }
   double hiAvg = sumHi / Oracle_HILOPeriod;
   double loAvg = sumLo / Oracle_HILOPeriod;
   if (close > hiAvg) g_prevHiloSide = 1;
   else if (close < loAvg) g_prevHiloSide = -1;
   int hilo = g_prevHiloSide;
   if (Oracle_HILOInvert) hilo = -hilo;
   if (hilo != 0) return hilo;                          // HiLo side is the signal
   return (close < ma) ? -1 : (close > ma ? 1 : 0);      // start-up fallback: EMA side
}

int g_prevN[2] = {0, 0};   // per-engine level count on the previous pass (cycle tally)

void OracleOnEngine(int magic)
{
   string sym = g_sym;
   int n, dir; double lots, avg, pl, last; datetime lt;
   Basket(sym, magic, n, dir, lots, avg, pl, last, lt);

   // Basket went flat since the last pass -> one cycle completed. Book its
   // realized P/L from the freshest closes of this magic (panel tally, GVs
   // survive restarts just like the MT5 build's counters).
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
      if (Oracle_BasketStopCooldownMin > 0)
         g_bstopUntil[EngineIdx(magic)] = TimeGMT() + Oracle_BasketStopCooldownMin * 60;
      return;
   }

   // Soft blocks for NEW entries/adds
   if (g_paused || InNewsWindow() || HourBlocked() || SchedBlocked() || TimeGMT() < g_volPauseUntil ||
       TimeGMT() < g_srvBlockUntil || ClosedOrWarmingUp() || InFridayPreClose()) return;

   bool spreadOK = (Oracle_MaxSpread <= 0) || (MarketInfo(sym, MODE_SPREAD) <= Oracle_MaxSpread);

   if (n == 0)
   {
      if (TimeGMT() < g_bstopUntil[EngineIdx(magic)]) return;
      if (!spreadOK) return;
      int bias = Bias();
      // One side per engine when both engines are on (Oracle 2.0 behavior);
      // a lone engine trades both sides, one basket at a time.
      int side = 0;
      if (Oracle_EngineA && Oracle_EngineB) side = (magic == MAGIC_A) ? 1 : -1;
      if (bias == 0 || (side != 0 && bias != side)) return;
      // EMAGATE: the HiLo alone always carries a side, so a closed basket re-arms
      // instantly. Requiring the EMA to agree gates only the NEW basket (adds keep
      // using the HiLo direction). Same switch as the MT5 build.
      if (EmaGateOn() && EmaSide() != bias) return;
      if (RegimeBlocked(bias)) return;   // do not arm a grid against a strong H1 trend
      if (OpenLevel(sym, magic, bias, 0))
      {
         g_lastAddTime[EngineIdx(magic)] = TimeCurrent();   // throttle the first add too
         SetBasketTP(sym, magic);
      }
      return;
   }

   bool depthOK = (n < EffMaxLevels());
   double adverse = (dir < 0) ? (bid - last) : (last - bid);
   double nextLot = EffLot() * MathPow(EffFactor(), n);
   // Throttle: the timer AND ticks run the grid, so without a minimum gap a burst
   // of ticks in one second adds several levels before the fresh order is visible,
   // stacking them pips apart and violating GridSize. One add per Oracle_MinSecsBetweenAdds.
   int ei2 = EngineIdx(magic);
   bool addThrottled = (Oracle_MinSecsBetweenAdds > 0 &&
                        TimeCurrent() - g_lastAddTime[ei2] < Oracle_MinSecsBetweenAdds);
   if (spreadOK && depthOK && !addThrottled && !RegimeBlocked(dir) && adverse >= EffGrid() * pip && (lots + nextLot) <= Oracle_MaxLot)
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
   if (Oracle_EngineA) OracleOnEngine(MAGIC_A);
   if (Oracle_EngineB) OracleOnEngine(MAGIC_B);
}

//==================================================================
// Overrides / presets (SYMBOL=TP,GRID,LOT,FACTOR,MAXLEV[,BSTOP])
//==================================================================
void SaveOverridesToGV()
{
   if (g_ovTP    > 0)  GlobalVariableSet(GV_OV_TP,    g_ovTP);
   if (g_ovGrid  > 0)  GlobalVariableSet(GV_OV_GRID,  g_ovGrid);
   if (g_ovLot   > 0)  GlobalVariableSet(GV_OV_LOT,   g_ovLot);
   if (g_ovFactor > 0) GlobalVariableSet(GV_OV_FACTOR, g_ovFactor);
   if (g_ovMaxLev >= 0) GlobalVariableSet(GV_OV_MAXLEV, g_ovMaxLev);
   if (g_ovBstop >= 0) GlobalVariableSet(GV_OV_BSTOP, g_ovBstop);
   if (g_ovEmaGate >= 0) GlobalVariableSet(GV_OV_EMAGATE, g_ovEmaGate);
}

void LoadOverridesFromGV()
{
   if (GlobalVariableCheck(GV_OV_TP))     g_ovTP     = GlobalVariableGet(GV_OV_TP);
   if (GlobalVariableCheck(GV_OV_GRID))   g_ovGrid   = GlobalVariableGet(GV_OV_GRID);
   if (GlobalVariableCheck(GV_OV_LOT))    g_ovLot    = GlobalVariableGet(GV_OV_LOT);
   if (GlobalVariableCheck(GV_OV_FACTOR)) g_ovFactor = GlobalVariableGet(GV_OV_FACTOR);
   if (GlobalVariableCheck(GV_OV_MAXLEV)) g_ovMaxLev = (int)GlobalVariableGet(GV_OV_MAXLEV);
   if (GlobalVariableCheck(GV_OV_BSTOP))  g_ovBstop  = GlobalVariableGet(GV_OV_BSTOP);
   if (GlobalVariableCheck(GV_OV_EMAGATE)) g_ovEmaGate = (int)GlobalVariableGet(GV_OV_EMAGATE);
}

// Re-anchor the Rule E daily baseline. Shared by the RESETDAY command and the
// panel button so both behave identically (MT5 parity: DoResetDay).
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
   return StringFormat("%s TP=%.0f GRID=%.0f LOT=%.2f FACTOR=%.2f MAXLEV=%d BSTOP=%.2f EMAGATE=%s",
                       g_sym, EffTP(), EffGrid(), EffLot(), EffFactor(), EffMaxLev(), EffBstop(),
                       EmaGateOn() ? "ON" : "OFF");
}

// Preset field order MUST match src-mt5/Cerberus.mq5 exactly - both platforms
// share the same symbol_presets.txt file: SYMBOL=TP,GRID,LOT,FACTOR,MAXLEV,BSTOP.
void SavePreset()
{
   string newLine = StringFormat("%s=%.0f,%.0f,%.2f,%.2f,%d,%.2f",
                    g_sym, EffTP(), EffGrid(), EffLot(), EffFactor(), EffMaxLev(), EffBstop());
   string keep[]; int nk = 0;
   int rh = FileOpen(PRESETS_FILE, FILE_READ | FILE_TXT | FILE_ANSI);
   if (rh != INVALID_HANDLE)
   {
      while (!FileIsEnding(rh))
      {
         string ln = FileReadString(rh);
         if (StringLen(ln) == 0) continue;
         if (StringFind(ln, g_sym + "=") == 0) continue;
         ArrayResize(keep, nk + 1); keep[nk++] = ln;
      }
      FileClose(rh);
   }
   int wh = FileOpen(PRESETS_FILE, FILE_WRITE | FILE_TXT | FILE_ANSI);
   if (wh == INVALID_HANDLE) { LogAction("WARNING", "SAVEPRESET: cannot write file"); return; }
   for (int i = 0; i < nk; i++) FileWriteString(wh, keep[i] + "\r\n");
   FileWriteString(wh, newLine + "\r\n");
   FileClose(wh);
   LogAction("SAVEPRESET", newLine);
}

bool LoadPreset(string sym)
{
   int rh = FileOpen(PRESETS_FILE, FILE_READ | FILE_TXT | FILE_ANSI);
   if (rh == INVALID_HANDLE) { LogAction("WARNING", "PRESET: no " + PRESETS_FILE); return false; }
   string found = "";
   while (!FileIsEnding(rh))
   {
      string ln = FileReadString(rh);
      if (StringFind(ln, sym + "=") == 0) { found = ln; break; }
   }
   FileClose(rh);
   if (found == "") { LogAction("WARNING", "PRESET: no entry for " + sym); return false; }
   // TP,GRID,LOT,FACTOR,MAXLEV,BSTOP - same layout as the MT5 build. A legacy
   // 5-field line (no FACTOR) is still readable: field 4 becomes MAXLEV as
   // before and FACTOR is simply left unset (falls back to the input default).
   string kv[]; if (StringSplit(found, '=', kv) < 2) return false;
   string v[]; int nv = StringSplit(kv[1], ',', v);
   if (nv >= 1 && StringToDouble(v[0]) > 0) g_ovTP     = StringToDouble(v[0]);
   if (nv >= 2 && StringToDouble(v[1]) > 0) g_ovGrid   = StringToDouble(v[1]);
   if (nv >= 3 && StringToDouble(v[2]) > 0) g_ovLot    = StringToDouble(v[2]);
   if (nv >= 4 && StringToDouble(v[3]) > 0) g_ovFactor = StringToDouble(v[3]);
   if (nv >= 5)                             g_ovMaxLev = (int)StringToInteger(v[4]);
   if (nv >= 6)                             g_ovBstop  = MathMax(0, StringToDouble(v[5]));
   SaveOverridesToGV();
   LogAction("PRESET", "loaded " + found + " -> " + ConfigLine());
   return true;
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
   else if (StringFind(cmd, "EMAGATE") == 0)
   {
      string ep[];
      if (StringSplit(cmd, ' ', ep) >= 2 && (ep[1] == "ON" || ep[1] == "OFF"))
      {
         g_ovEmaGate = (ep[1] == "ON") ? 1 : 0;
         SaveOverridesToGV();
         LogAction("EMAGATE", StringFormat("new-basket EMA gate %s by command", ep[1]));
      }
      else LogAction("WARNING", "syntax: EMAGATE ON|OFF");
   }
   else if (cmd == "ORACLE_ON")  { g_oracleOn = true;  GlobalVariableSet(GV_ORACLE_ON, 1); LogAction("ORACLE", "engine ON"); }
   else if (cmd == "ORACLE_OFF") { g_oracleOn = false; GlobalVariableSet(GV_ORACLE_ON, 0); LogAction("ORACLE", "engine OFF"); }
   else if (cmd == "CONFIG")     LogAction("CONFIG", ConfigLine());
   else if (cmd == "PANELDUMP")  PanelDump();
   else if (cmd == "SAVEPRESET") SavePreset();
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
   else if (StringFind(cmd, "PRESET") == 0)
   {
      string parts[]; if (StringSplit(raw, ' ', parts) >= 2) LoadPreset(parts[1]);
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
   else if (StringFind(cmd, "SYMBOL") == 0)
   {
      string parts[];
      if (StringSplit(raw, ' ', parts) >= 2)
      {
         CloseBasket(g_sym, MAGIC_A, "symbol switch");
         CloseBasket(g_sym, MAGIC_B, "symbol switch");
         g_sym = parts[1];
         SymbolSelect(g_sym, true);
         g_prevHiloSide = 0; g_openedAt = 0; g_sawClosed = false;
         LogAction("SYMBOL", "now trading " + g_sym + " (basket flattened)");
      }
   }
   else if (StringFind(cmd, "BUY") == 0 || StringFind(cmd, "SELL") == 0)
   {
      string parts[]; int np = StringSplit(raw, ' ', parts);
      if (np >= 3)
      {
         string ms = parts[1]; double ml = StringToDouble(parts[2]);
         SymbolSelect(ms, true); RefreshRates();
         int mt = (StringFind(cmd, "BUY") == 0) ? OP_BUY : OP_SELL;
         double mp = (mt == OP_BUY) ? MarketInfo(ms, MODE_ASK) : MarketInfo(ms, MODE_BID);
         int mtk = OrderSend(ms, mt, ml, mp, 300, 0, 0, "Cerberus4 manual", 777999, 0, clrYellow);
         LogAction("MANUAL", StringFormat("%s %s %.2f -> %s", cmd, ms, ml, mtk > 0 ? "#" + IntegerToString(mtk) : "FAILED err=" + IntegerToString(GetLastError())));
      }
      else LogAction("WARNING", "syntax: BUY <sym> <lots> / SELL <sym> <lots>");
   }
   else if (StringFind(cmd, "SET") == 0)
   {
      string parts[]; int np = StringSplit(raw, ' ', parts);
      for (int i = 1; i < np; i++)
      {
         string kvp[]; if (StringSplit(parts[i], '=', kvp) != 2) continue;
         string key = kvp[0]; StringToUpper(key);
         double val = StringToDouble(kvp[1]);
         // Homologated to MT5: assign the value as-is (no val>0 filter) and warn
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
// Closed-history tally - MQL4 order-history equivalent of the MT5 build's
// TallyClosedHistory(): same fields (closed/wins/losses/realized/closedToday/
// avgWin/avgLoss), same "win if p>=0" rule, same "today" cutoff at 00:00 GMT.
// MT4 has no deal ticket model, so this walks OrdersHistoryTotal() filtered to
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
   s += "\"ea\":\"Cerberus4\",\"version\":\"1.15\",";
   s += "\"gmt\":\"" + TimeToString(TimeGMT(), TIME_DATE | TIME_SECONDS) + "\",";
   s += "\"status\":\"" + (g_paused ? "PAUSED_MANUAL" : (TimeGMT() < g_volPauseUntil ? "PAUSED_VOLATILITY" : (InNewsWindow() ? "PAUSED_NEWS" : "RUNNING"))) + "\",";
   s += StringFormat("\"config\":{\"symbol\":\"%s\",\"tp\":%.0f,\"grid\":%.0f,\"lot\":%.2f,\"maxlev\":%d},", g_sym, EffTP(), EffGrid(), EffLot(), EffMaxLev());
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
// Panel (CB_ prefix) — EXACT transcription of the MT5 build's panel:
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
   if (r == 2) return "MEDIUM";   // homologated to MT5 (was "HIGH")
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
   else if (inWin)       SetLine(line++, PanelFit("# CERBERUS: NEWS PAUSE: " + evName), clrTomato);
   else if (nowG < g_volPauseUntil)
                         SetLine(line++, PanelFit("# CERBERUS: VOLATILITY PAUSE only " + g_sym), clrTomato);
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
      string tag = (UseHourFilter && hr >= HourBlockRisk) ? " >> NO ENTRIES" :
                   (!UseHourFilter ? " (filter OFF)" : "");
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
      int toPause = toEvent - MinutesBefore * 60;
      SetLine(line++, PanelFit("NEXT: USD " + g_evTitle[nextIdx]), clrKhaki);
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
              (Oracle_MaMethod == 1) ? "EMA" : "SMA", Oracle_MaPeriod, (Oracle_TF > 0) ? Oracle_TF : 1,
              g_oracleOn ? "ON" : "OFF", EffTP(), EffGrid(), EffLot(), EffFactor(),
              Oracle_EngineA ? "A" : "-", Oracle_EngineB ? "B" : "-"),
              g_oracleOn ? clrLightGreen : cDim);

      double exposure = 0;
      double pip = StratPip(g_sym);
      double sbid = MarketInfo(g_sym, MODE_BID);
      int engines[2]; engines[0] = MAGIC_A; engines[1] = MAGIC_B;
      for (int e = 0; e < 2; e++)
      {
         int n, dir; double totLots, avg, pl, lastLevel; datetime lt;
         Basket(g_sym, engines[e], n, dir, totLots, avg, pl, lastLevel, lt);
         exposure += totLots;
         if (n == 0)
         {
            if (nowG < g_volPauseUntil)
               SetLine(line++, StringFormat("%-8s e%d VOL PAUSE (rule C)", g_sym, e), cWarn);
            else if (HourBlocked())
               SetLine(line++, StringFormat("%-8s e%d HOUR BLOCK %s", g_sym, e, RiskName(HourRisk(NowMinUTC()))), cWarn);
            else
            {
               int bias = Bias();
               SetLine(line++, StringFormat("%-8s e%d  no basket  bias %s", g_sym, e,
                       bias > 0 ? "BUY" : bias < 0 ? "SELL" : "-"),
                       bias > 0 ? cUp : bias < 0 ? cDown : cDim);
            }
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
   SetLine(line++, StringFormat("Brakes (guardian): day -%.0f | pos -%.0f | rule C closes",
           MaxDailyLossUSD, MaxLossPerTradeUSD), cDim);

   // --- Account
   double ml = (AccountMargin() > 0) ? AccountEquity() / AccountMargin() * 100.0 : 999999;
   color mlClr = clrLightGreen;
   if (MinMarginLevelPct > 0 && ml < MinMarginLevelPct * 1.25) mlClr = clrTomato;
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
// be diffed against the MT5 layout without a screenshot.
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
   string syms = Oracle_Symbols;
   string list[]; int nl = StringSplit(syms, ',', list);
   g_sym = (nl > 0) ? list[0] : Symbol();
   if (g_sym == "") g_sym = Symbol();
   SymbolSelect(g_sym, true);

   g_paused = (GlobalVariableCheck(GV_PAUSE) && GlobalVariableGet(GV_PAUSE) > 0);
   g_oracleOn = !(GlobalVariableCheck(GV_ORACLE_ON) && GlobalVariableGet(GV_ORACLE_ON) == 0);
   g_bstopUntil[0] = 0; g_bstopUntil[1] = 0;
   g_peakEquity = AccountEquity();   // seed drawdown baseline, same as the MT5 build
   LoadOverridesFromGV();

   if (StringLen(TestEventMinutes) > 0)
   {
      int tmins = (int)StringToInteger(TestEventMinutes);
      if (tmins > 0) { g_nextEvent = TimeGMT() + tmins * 60; g_nextEventTxt = "USD TEST INPUT"; }
   }

   PanelCreate();
   EventSetTimer(5);
   LogAction("INIT", StringFormat("Cerberus4 v1.15 on [%s] (%s%d + HILO%d tf%d, effective %s, engines %s%s)",
             g_sym, (Oracle_MaMethod == 1) ? "EMA" : "SMA", Oracle_MaPeriod, Oracle_HILOPeriod,
             (Oracle_TF > 0) ? Oracle_TF : 1, ConfigLine(),
             Oracle_EngineA ? "A" : "-", Oracle_EngineB ? "B" : "-"));
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
   EvaluateNewsState();          // news: close all + AT off on entering a window (homologated to MT5)
   CheckVolatilitySpike();       // rule C ATR spike / window: once per closed M1 bar
   CheckSpikePipsLive();         // rule C fixed-pips: intrabar (no-op unless VolSpikePips>0)
   ApplyDefenseRules();
   PreCloseFlatten();
   // With AutoTrading off (news window, manual pause, rule E, scheduler HARD) the
   // strategy does not run - same gate as MT5's `if (AutoTradingOn() && OracleOn())`.
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
   // fast path (homologated to MT5's OnTick): news state, then rule C - the ATR
   // spike/window once per closed bar (CheckVolatilitySpike self-guards on
   // g_lastM1Bar) and the fixed-pips spike intrabar (CheckSpikePipsLive) - then
   // manage basket TPs and the basket stop tick-by-tick.
   EvaluateNewsState();
   CheckVolatilitySpike();
   CheckSpikePipsLive();
   if (AutoTradingOn() && TradingPermitted() && !g_paused && g_oracleOn)
   {
      if (Oracle_EngineA) OracleOnEngine(MAGIC_A);
      if (Oracle_EngineB) OracleOnEngine(MAGIC_B);
   }
}
