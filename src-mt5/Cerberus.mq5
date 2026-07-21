//+------------------------------------------------------------------+
//| Cerberus.mq5 - guardian + ORACLE strategy in a single EA         |
//|                                                                  |
//| Heads:                                                           |
//|  GUARDIAN (always on): news windows (ForexFactory calendar with  |
//|    disk cache), volatility circuit breaker (rule C, per symbol), |
//|    defense rules A (adverse pips), B (margin), D (USD/position), |
//|    E (daily loss), command channel ng_command.txt and status     |
//|    file ng_status.json.                                          |
//|  ORACLE (magics 7799/9977): faithful replica of the Oracle 2.0   |
//|    black-box bot. Two engines (A/B), each: direction filter      |
//|    (EMA 34 + HILO 3 channel on M1), enters with a small TP, and  |
//|    on adverse move adds an ADDITIVE grid level (constant lot,     |
//|    GridFactor=1.0 - NOT martingale x2), closing the WHOLE basket  |
//|    at TP from the weighted average. Optional per-basket stop      |
//|    (Oracle_BasketStopUSD, default OFF - Oracle itself has none);  |
//|    the guardian (rules A-E) remains the global net.               |
//|    Pip scale for the strategy: 1 pip = $0.01 on XAUUSDm.          |
//|                                                                  |
//| Persisted state (survives restarts; legacy NG_/CB_ GV prefixes): |
//|  NG_ManualPause / NG_DisabledByGuard / NG_DayDate / NG_DayStartBal|
//|  CB_OracleOn (def 1)                                             |
//|                                                                  |
//| Terminal requirements:                                            |
//|  - Allow algorithmic trading + Allow DLL imports                  |
//|  - WebRequest URL whitelisted: https://nfs.faireconomy.media      |
//|  - HEDGING account (baskets open several positions per symbol)   |
//| NOTE: XAUUSDm on Exness quotes with 3 decimals - use              |
//| PipSizeOverride=0.1 so a "pip" stays $0.10 (rule A guardian).     |
//+------------------------------------------------------------------+
#property copyright "Harrinson Gutierrez"
#property version   "1.15"

#include <Trade\Trade.mqh>

#import "user32.dll"
   long GetAncestor(long hWnd, int gaFlags);
   int  PostMessageW(long hWnd, int Msg, long wParam, long lParam);
#import

#define WM_COMMAND          0x0111
#define MT5_CMD_ALGOTRADING 32851
#define GA_ROOT             2

#define FEED_URL   "https://nfs.faireconomy.media/ff_calendar_thisweek.json"
#define CACHE_FILE "ff_cache.json"
#define GV_GUARD   "NG_DisabledByGuard"
#define GV_MANUAL  "NG_ManualPause"
#define GV_SCHED   "CB_DisabledBySched"   // scheduler turned AT off (survives restart; separate from GV_GUARD so news and scheduler do not fight over the button)
#define GV_ORACLE  "CB_OracleOn"
// Runtime-override GlobalVariables (survive restarts). Symbol override is a
// string, so it lives in a file (ng_active_symbol.txt), not a GV.
#define GV_OV_TP     "CB_ovTP"
#define GV_OV_GRID   "CB_ovGrid"
#define GV_OV_LOT    "CB_ovLot"
#define GV_OV_FACTOR "CB_ovFactor"
#define GV_OV_MAXLEV "CB_ovMaxLev"
#define GV_OV_BSTOP  "CB_ovBstop"
#define GV_OV_EMAGATE "CB_ovEmaGate"
#define ACTIVE_SYMBOL_FILE "ng_active_symbol.txt"
#define PRESETS_FILE       "symbol_presets.txt"
#define MAX_EVENTS 200

#define MAGIC_ORACLE_A 7799
#define MAGIC_ORACLE_B 9977
#define MAGIC_CMD      777999

//--- Inputs: GUARDIAN ---------------------------------------------
input string PairsToWatch      = "XAUUSDm";           // Watched pairs (CSV; Exness gold = XAUUSDm)
input int    MinutesBefore     = 30;                  // News window: minutes before the event
input int    MinutesAfter      = 30;                  // News window: minutes after
input int    FeedRefreshMinutes= 60;                  // Calendar refresh
input bool   ClosePendingOrders= true;                // Also delete pending orders
input string TestEventMinutes  = "";                  // Test mode: fake events, CSV of minutes
input string LogFileName       = "Cerberus_log.csv";  // Log in MQL5/Files
input double MaxAdversePips    = 300;                 // Rule A: close a position N pips against (0=off)
input double RuleA_xATR        = 15;                  // Rule A: per-symbol floor, N x ATR(M1) (fixed pips misfire on crypto; 0=pips only)
input double PipSizeOverride   = 0.1;                 // Manual pip size (XAUUSDm has 3 decimals: use 0.1)
input double MinMarginLevelPct = 200;                 // Rule B: minimum margin level % (0=off)
input double MaxLossPerTradeUSD= 60;                  // Rule D: close a position losing > N USD (0=off)
input double MaxDailyLossUSD   = 200;                 // Rule E: daily loss > N USD -> close ALL and pause (0=off)
input double VolSpikeATRmult   = 5;                   // Rule C: M1 candle > N x ATR(M1) -> pause (0=off)
input double VolSpikePips      = 0;                   // Rule C: M1 candle >= N FIXED pips -> pause (0=off)
input bool   UseHourFilter     = true;                // Hour filter: ORACLE does not open in VERY HIGH windows (gold table, UTC)
input int    HourBlockRisk     = 3;                   // Hour filter: block risk >= N (3=VERY HIGH only, 2=also MEDIUM)
//--- Scheduler: user-defined "no new entries" windows (UTC "HH:MM"; Start==End = unused).
// A SOFT block: like the hour filter it only stops NEW entries/adds; it never
// touches the global AutoTrading button and never closes an open basket (its TP
// still works). Conceived from TradingScheduler.mq4 but adapted to Cerberus'
// design: times are UTC (same base as HourRisk / the status JSON), not broker.
input bool   UseSchedule       = false;               // Scheduler: block NEW entries inside the windows below (soft, like the hour filter; false=off)
input bool   SchedKillAT        = false;              // Scheduler action: false=SOFT (only block Cerberus entries). true=HARD: on entering a window CLOSE ALL orders and turn the GLOBAL AutoTrading button OFF (affects every EA, like the old AlgoGuard), re-enabling it on exit. Lock in GV survives restarts.
// Defaults mirror the gold "VERY HIGH" bands of HourRisk() (08:00-09:30 London
// open, 12:00-15:30 US data + NY open, in UTC). With HourBlockRisk=3 the hour
// filter already blocks these; the scheduler is a redundant, EDITABLE copy so
// you can widen/narrow or add windows without recompiling the risk table.
input string Sched1Start       = "08:00";             // Window 1 start (UTC "HH:MM"; London open). Start==End disables it
input string Sched1End         = "09:30";             // Window 1 end (half-open: at End trading is back on)
input string Sched2Start       = "12:00";             // Window 2 start (UTC; US data + NY open)
input string Sched2End         = "15:30";             // Window 2 end
input string Sched3Start       = "";                  // Window 3 start (UTC; empty=unused)
input string Sched3End         = "";                  // Window 3 end
input string Sched4Start       = "";                  // Window 4 start (UTC; empty=unused)
input string Sched4End         = "";                  // Window 4 end
input bool   SchedSunday       = true;                // Allow new entries on Sunday (UTC day). false=no entries all day
input bool   SchedMonday       = true;                // Allow new entries on Monday
input bool   SchedTuesday      = true;                // Allow new entries on Tuesday
input bool   SchedWednesday    = true;                // Allow new entries on Wednesday
input bool   SchedThursday     = true;                // Allow new entries on Thursday
input bool   SchedFriday       = true;                // Allow new entries on Friday
input bool   SchedSaturday     = true;                // Allow new entries on Saturday
input bool   UseSessionFilter  = true;                // Market-hours filter: ask the BROKER (SymbolInfoSessionTrade) if the symbol is tradable now; no entries while its market is closed / in the daily rollover pause
input int    PreCloseCloseMin  = 5;                   // Close baskets this many minutes BEFORE the symbol's session closes (weekend gap protection; 0=off, keep positions)
input bool   PreCloseWeekendOnly = true;              // Pre-close ONLY before the weekly (Friday/weekend) close, not the nightly rollover (research: flatten for the weekend gap; the daily rollover only needs entries blocked). false=flatten on every session close.
input int    SrvBlockBackoffMin = 10;                 // When the SERVER rejects with 10026 (AutoTrading disabled by server), pause that symbol this many minutes instead of hammering thousands of retries (BTC's nightly server-maintenance window). 0=off.
input int    LocalBlockBackoffSec = 10;               // When the CLIENT TERMINAL rejects with 10027 (this EA not armed yet, e.g. the seconds right after an INIT), pause that symbol this many SECONDS. It clears by itself - do not spend the 10-min server backoff on it.
input int    WeekendGapHours    = 6;                  // A session close counts as the WEEKEND close only if the market does not reopen within this many hours (so BTC's daily midnight close is NOT treated as a weekend close).
input int    VolWindowM1Bars   = 5;                   // Rule C: M1 candle window for cumulative move
input double VolWindowATRmult  = 8;                   // Rule C: window range > N x ATR(M1) -> pause (0=off)
input int    VolATRPeriod      = 20;                  // Rule C: reference M1 ATR period
input int    VolPauseMinutes   = 3;                   // Rule C: cooldown after the LAST violent candle
input bool   CloseOnVolSpike   = false;               // Rule C: also close that symbol's basket

//--- Inputs: ORACLE (faithful replica of Oracle 2.0; see spec) -----
// Pip scale for these: 1 pip = $0.01 on XAUUSDm (Point*10, 3 decimals),
// NOT the guardian's PipSizeOverride. So TP=20 -> $0.20, GridSize=50 -> $0.50.
input string Oracle_Symbols    = "XAUUSDm"; // Cerberus trades ONE symbol; this is the default at first start. Change it live with SYMBOL <sym> / PRESET <sym> (persists). If a CSV is given, only the first entry is used.
input ENUM_TIMEFRAMES Oracle_TF = PERIOD_M1; // ORACLE: signal TF (Oracle runs on M1)
input bool   Oracle_EngineA    = true;   // ORACLE: engine A on (magic 7799)
input bool   Oracle_EngineB    = true;   // ORACLE: engine B on (magic 9977)
input double Oracle_FixedLot   = 0.01;   // ORACLE: fixed lot per level (LotMode=1)
input int    Oracle_TakeProfit = 20;     // ORACLE: basket TP in pips from the weighted average (InpTakeProfit=20). Common server-side TP on all grid orders, re-anchored to the average on each add.
input int    Oracle_GridSize   = 50;     // ORACLE: add a grid level every N pips against
input double Oracle_GridFactor = 1.0;    // ORACLE: 1.0 = constant lot (additive, NOT martingale)
input int    Oracle_MinSecsBetweenAdds = 2; // ORACLE: min seconds between grid adds of the same engine. OnTimer AND OnTick both run the grid, so a fast tick burst could add several levels in one second before the fresh order shows in PositionsTotal - stacking them pips apart and violating GridSize. 0 = off.
input double Oracle_MaxLot     = 99.0;   // ORACLE: hard total-lot cap (faithful to Oracle)
input int    Oracle_MaPeriod   = 34;     // ORACLE: bias EMA period (close)
input int    Oracle_MaMethod   = 1;      // ORACLE: MA method (1=EMA)
input int    Oracle_HILOPeriod = 3;      // ORACLE: HILO channel lookback
input bool   Oracle_HILOInvert = false;  // ORACLE: invert HILO signal
input int    Oracle_MaxSpread  = 240;    // ORACLE: skip entries if spread > N points (InpMaxSpread; 0=off)
input int    Oracle_MaxGridLevels = 0;   // ORACLE: absolute hard cap on grid depth per engine (0 = use the capital-proportional cap below). Oracle itself has NO level cap (it just survives on a $4k cushion); the proportional cap is OUR improvement so the risk is bounded on any account.
input double Oracle_BaseCapital    = 1000; // ORACLE: declared account capital used to size the grid depth cap (set to your real balance: 1000 or 4000). Explicit and STABLE - unlike reading the live balance, this does not drift as the P/L moves, so the level cap is predictable. Change it if you switch accounts.
input double Oracle_DollarsPerLevel = 180; // ORACLE: allow 1 grid level per N dollars of BaseCapital (Oracle ran ~22 levels on $4k => ~$180/level). So $1k->5 levels, $4k->22, homologated to the declared capital. 0 = disable the proportional cap.
input bool   Oracle_NewBasketNeedsEMA = false; // ORACLE: a NEW basket also needs the EMA to agree with the HiLo side (adds are never gated). The HiLo persists a side forever, so without this Cerberus re-arms a basket the same second it closed one - measured 2026-07-21: 98.9% of the time in market and 26 baskets/21 min against Oracle 2.0's 72.2% and 11. Hot-switchable with EMAGATE ON|OFF.
input double Oracle_BasketStopUSD  = 0;    // ORACLE: cut the whole basket (that engine's symbol+magic) when its floating P/L <= -N USD (0 = off). Sizing rule: max ~2.5x the average basket win (72% win rate breaks even at 2.57x). Hot-tunable with BSTOP <usd>.
input int    Oracle_BasketStopCooldownMin = 30; // ORACLE: minutes without opening a NEW basket on that engine after a basket-stop cut, so we do not re-enter inside the same move (0 = off)
input bool   Oracle_UseRegimeFilter = false; // ORACLE: veto entries/adds against a strong H1 trend (soft block, twin of the hour filter - never closes anything)
input int    Oracle_RegimeADX      = 27;     // ORACLE: ADX(14) H1 above this = strong trend; blocks the side fading it (DI+ vs DI-)
input double Oracle_RegimeATRDist  = 3.0;    // ORACLE: price further than N x ATR(14) H1 from the EMA200 H1, on the side the signal would fade, also blocks (0 = ADX only)
input int    Oracle_OpenWarmupMin  = 15;     // ORACLE: veto entries/adds the first N minutes after a session (re)open - Sunday open AND the daily rollover resume quote thinly and spike the ATR-relative rule C (0 = off; crypto never closes, so unaffected)
input bool   Oracle_UseServerSL     = true;  // ORACLE: also arm a server-side SL per position, sized so the WHOLE basket losing at once approximates Oracle_BasketStopUSD. Broker executes it even if our close orders get rejected (2026-07-20: basket stop fired correctly but the server refused every close retry for ~2h while the basket kept moving, -$50 worse than the stop). No-op when Oracle_BasketStopUSD<=0.

//==================================================================
// Global state
//==================================================================
CTrade   g_trade;                 // single CTrade; magic is set before each open

// --- Guardian
string   g_currencies[];
string   g_pairs[];
int      g_atrM1[];
datetime g_lastM1Bar[];
datetime g_volPauseSym[];    // rule C pause PER SYMBOL (not global)
string   g_evTitle[MAX_EVENTS];
string   g_evCountry[MAX_EVENTS];
datetime g_evTime[MAX_EVENTS];
int      g_evCount = 0;
datetime g_testTimes[];
datetime g_lastFeedOk = 0;
datetime g_lastFeedTry = 0;
datetime g_lastStatusWrite = 0;
string   g_feedStatus = "no data";
string   g_lastAction = "-";
bool     g_wasInWindow = false;
string   g_activeEventName = "";

// --- Scheduler (parsed once at OnInit; OnTimer/gates then compare integers)
int      g_schStart[4];       // window start minute-of-UTC-day, -1 = unused
int      g_schEnd[4];         // window end minute
bool     g_schDay[7];         // index = UTC day of week, 0 = Sunday

// --- Oracle (parallel arrays per traded symbol)
string   g_oSym[];
int      g_oMA[];           // bias EMA handle per symbol
datetime g_oOpenedAt[];     // GMT of the last closed->open transition seen (0 = none yet)
bool     g_oSawClosed[];    // true once the market was seen closed (arms the warm-up)
datetime g_oSrvBlock[];     // server-disabled-AT backoff per symbol (retcode 10026/10027): skip until this GMT
int      g_oCycles = 0;     // completed baskets (TP closes), for the panel
double   g_oRealized = 0;   // realized USD from basket closes
datetime g_oBstopUntil[2];  // basket-stop cooldown per engine (0=A, 1=B)
datetime g_oLastAddTime[2]; // GMT of the last level opened per engine: throttles
                            // adds so a burst of ticks in one second cannot stack
                            // levels before the fresh order shows in PositionsTotal
int      g_oADX    = INVALID_HANDLE;  // regime filter: ADX(14) H1 on the traded symbol
int      g_oEMA200 = INVALID_HANDLE;  // regime filter: EMA200 H1
int      g_oATRH1  = INVALID_HANDLE;  // regime filter: ATR(14) H1
bool     g_regimeBlocked = false;     // last regime-veto verdict, for the status JSON
int      g_oBstopHits = 0;  // basket-stop cuts today
int      g_oBstopDay = 0;   // year*1000+day_of_year the hit counter belongs to
string   g_oLastDecision = "starting...";
double   g_peakEquity = 0;  // running max equity, for drawdown in the status file

// --- Runtime overrides: shadow the Oracle_* inputs so TP/grid/lot/factor and
// the traded symbol can be changed by hot command WITHOUT recompiling or
// restarting. Seeded from the inputs at OnInit (or from GlobalVariables if a
// previous session set them - they survive restarts). Oracle reads THESE, not
// the raw inputs. See EffTP()/EffGrid()/... accessors below.
double   g_ovTP      = 0;   // effective TakeProfit (pips); 0 => use input
double   g_ovGrid    = 0;   // effective GridSize (pips)
double   g_ovLot     = 0;   // effective FixedLot
double   g_ovFactor  = 0;   // effective GridFactor
int      g_ovMaxLev  = -1;  // effective MaxGridLevels (-1 => use input)
double   g_ovBstop   = -1;  // effective BasketStopUSD (-1 => use input; 0 is a valid "off")
int      g_ovEmaGate = -1;  // effective NewBasketNeedsEMA (-1 => use input, 0 off, 1 on)

//==================================================================
// Common helpers
//==================================================================
double IndValue(int handle, int shift)
{
   double v[1];
   if (handle == INVALID_HANDLE) return 0;
   if (CopyBuffer(handle, 0, shift, 1, v) != 1) return 0;
   return v[0];
}

// Same, for multi-buffer indicators (iADX: 0=main, 1=DI+, 2=DI-).
double IndValueBuf(int handle, int buffer, int shift)
{
   double v[1];
   if (handle == INVALID_HANDLE) return 0;
   if (CopyBuffer(handle, buffer, shift, 1, v) != 1) return 0;
   return v[0];
}

// Pip per symbol. The override ONLY applies to metals (XAUUSDm quotes with 3
// decimals so Point*10 would be $0.01); on 5-digit FX Point*10 = 0.0001 is OK.
double PipSize(string sym)
{
   string up = sym; StringToUpper(up);
   bool metal = (StringFind(up, "XAU") == 0 || StringFind(up, "XAG") == 0 ||
                 StringFind(up, "GOLD") == 0 || StringFind(up, "SILVER") == 0);
   if (PipSizeOverride > 0 && metal) return PipSizeOverride;
   return SymbolInfoDouble(sym, SYMBOL_POINT) * 10;
}

bool AutoTradingOn() { return (bool)TerminalInfoInteger(TERMINAL_TRADE_ALLOWED); }

// TERMINAL_TRADE_ALLOWED is the GLOBAL AutoTrading button; MQL_TRADE_ALLOWED is
// THIS EA's own permission ("Allow Algo Trading" in its properties, and the window
// right after an INIT while the terminal re-arms the expert). Without the second
// check the EA sends orders that can only come back as 10027 - the MT4 twin of this
// hole self-inflicted a 10-minute entry block after every restart.
bool TradingPermitted()
{
   if (MQLInfoInteger(MQL_TRADE_ALLOWED)) return true;
   static datetime lastNotReadyLog = 0;
   if (TimeGMT() - lastNotReadyLog >= 60)
   {
      lastNotReadyLog = TimeGMT();
      LogAction("AT_NOT_READY", "terminal does not allow this EA to trade (MQL_TRADE_ALLOWED false): re-init window, or 'Allow Algo Trading' unchecked in the EA properties");
   }
   return false;
}

// Symbol class: 0=FX, 1=metal, 2=crypto. Basket size and stop are set per
// class because one BTC/gold leg weighs far more in USD than an FX leg, so
// the same basket depth produces very different drawdowns.
int SymClass(string sym)
{
   string up = sym; StringToUpper(up);
   if (StringFind(up, "BTC") == 0 || StringFind(up, "ETH") == 0 ||
       StringFind(up, "XRP") == 0 || StringFind(up, "LTC") == 0) return 2;
   if (StringFind(up, "XAU") == 0 || StringFind(up, "XAG") == 0 ||
       StringFind(up, "GOLD") == 0 || StringFind(up, "SILVER") == 0) return 1;
   return 0;
}

//------------------------------------------------------------------
// Hour filter: gold risk table by UTC window (built from Colombia
// trading hours; Colombia = UTC-5, no DST).
// 0=VERY LOW 1=LOW 2=MEDIUM 3=VERY HIGH. Table lives in UTC minutes.
//------------------------------------------------------------------
int HourRisk(int minUTC)   // minUTC = minute of the UTC day [0,1440)
{
   // start of each window (UTC min) and its risk; 23:00-07:00 VERY LOW wraps
   static int rStart[10] = {0, 420, 480, 570, 720, 930, 1020, 1140, 1260, 1380};
   static int rRisk [10] = {0,   2,   3,   2,   3,   2,    1,    2,    1,    0};
   int r = 0;
   for (int i = 0; i < 10; i++)
      if (minUTC >= rStart[i]) r = rRisk[i];
   return r;
}

int NowMinUTC()
{
   MqlDateTime dt;
   TimeToStruct(TimeGMT(), dt);
   return dt.hour * 60 + dt.min;
}

bool HourBlocked() { return UseHourFilter && HourRisk(NowMinUTC()) >= HourBlockRisk; }

//------------------------------------------------------------------
// Scheduler: user-defined "no new entries" windows (UTC). A SOFT block,
// twin of HourBlocked(): it only vetoes new entries/adds, never touches
// the global AutoTrading button and never closes a basket. Ported from
// TradingScheduler.mq4 but on the UTC clock Cerberus already uses.
//------------------------------------------------------------------

// Parse "HH:MM" into a minute-of-day. Returns -1 for empty/malformed input, so
// a bad value disables that window instead of silently becoming midnight.
int SchedParseHHMM(string s, string inputName)
{
   StringTrimLeft(s);
   StringTrimRight(s);
   if (StringLen(s) == 0) return -1;                 // empty = window unused
   int colon = StringFind(s, ":");
   if (colon < 1)
   {
      LogAction("SCHED_WARN", inputName + "=\"" + s + "\" is not HH:MM -> window disabled");
      return -1;
   }
   int hh = (int)StringToInteger(StringSubstr(s, 0, colon));
   int mm = (int)StringToInteger(StringSubstr(s, colon + 1));
   if (hh < 0 || hh > 23 || mm < 0 || mm > 59)
   {
      LogAction("SCHED_WARN", inputName + "=\"" + s + "\" out of range -> window disabled");
      return -1;
   }
   return hh * 60 + mm;
}

// True if UTC minute m is inside window i. Half-open [start, end): at exactly
// End trading is back on. Handles windows that wrap past midnight (start > end).
bool SchedInWindow(int i, int m)
{
   int s = g_schStart[i], e = g_schEnd[i];
   if (s < 0 || e < 0 || s == e) return false;       // unused window
   if (s < e) return (m >= s && m < e);              // same-day window
   return (m >= s || m < e);                         // wraps past midnight
}

// The whole scheduler decision: are NEW entries blocked right now? A non-trading
// UTC weekday beats every window (matches TradingScheduler's day-off semantics).
bool SchedBlocked()
{
   if (!UseSchedule) return false;
   MqlDateTime dt;
   TimeToStruct(TimeGMT(), dt);                       // UTC, same base as HourRisk
   if (!g_schDay[dt.day_of_week]) return true;        // whole UTC day is off
   int m = dt.hour * 60 + dt.min;
   for (int i = 0; i < 4; i++)
      if (SchedInWindow(i, m)) return true;
   return false;
}

// Parse the inputs once. Called from OnInit, before the gates run.
void SchedInit()
{
   g_schStart[0] = SchedParseHHMM(Sched1Start, "Sched1Start");
   g_schEnd  [0] = SchedParseHHMM(Sched1End,   "Sched1End");
   g_schStart[1] = SchedParseHHMM(Sched2Start, "Sched2Start");
   g_schEnd  [1] = SchedParseHHMM(Sched2End,   "Sched2End");
   g_schStart[2] = SchedParseHHMM(Sched3Start, "Sched3Start");
   g_schEnd  [2] = SchedParseHHMM(Sched3End,   "Sched3End");
   g_schStart[3] = SchedParseHHMM(Sched4Start, "Sched4Start");
   g_schEnd  [3] = SchedParseHHMM(Sched4End,   "Sched4End");
   g_schDay[0] = SchedSunday;    g_schDay[1] = SchedMonday;  g_schDay[2] = SchedTuesday;
   g_schDay[3] = SchedWednesday; g_schDay[4] = SchedThursday;
   g_schDay[5] = SchedFriday;    g_schDay[6] = SchedSaturday;
   if (UseSchedule)
      LogAction("SCHED_INIT", StringFormat("windows(UTC) %s-%s %s-%s %s-%s %s-%s",
                Sched1Start, Sched1End, Sched2Start, Sched2End,
                Sched3Start, Sched3End, Sched4Start, Sched4End));
}

//------------------------------------------------------------------
// Market-hours filter (broker-authoritative). Instead of a hand-kept
// UTC table (fragile against server DST / GMT offset), we ask MT5 the
// symbol's own trading sessions. This covers the Friday weekly close,
// the daily rollover pause and broker holidays with zero maintenance.
//------------------------------------------------------------------

// Minute-of-day (server time) that "now" falls on, and today's weekday.
int SrvMinAndDow(ENUM_DAY_OF_WEEK &dow)
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);   // server time - sessions are in server time
   dow = (ENUM_DAY_OF_WEEK)dt.day_of_week;
   return dt.hour * 60 + dt.min;
}

// True if the symbol is inside a trading session right now (per the broker).
bool InTradingSession(string sym)
{
   ENUM_DAY_OF_WEEK dow;
   int now = SrvMinAndDow(dow);
   datetime from, to;
   for (int i = 0; ; i++)
   {
      if (!SymbolInfoSessionTrade(sym, dow, i, from, to)) break;
      int f = (int)(from / 60);   // session bounds come as seconds from midnight
      int t = (int)(to   / 60);
      if (now >= f && now < t) return true;
   }
   return false;
}

// Tradable now = broker allows trading on the symbol AND we are in session.
// TRADE_MODE_DISABLED / CLOSEONLY also block new entries. Unknown symbols or
// brokers that expose no sessions fall back to "open" (never freeze trading
// on a data quirk).
bool MarketOpen(string sym)
{
   if (!UseSessionFilter) return true;
   long tm = SymbolInfoInteger(sym, SYMBOL_TRADE_MODE);
   if (tm == SYMBOL_TRADE_MODE_DISABLED || tm == SYMBOL_TRADE_MODE_CLOSEONLY)
      return false;
   datetime dummyFrom, dummyTo;
   ENUM_DAY_OF_WEEK dow; SrvMinAndDow(dow);
   if (!SymbolInfoSessionTrade(sym, dow, 0, dummyFrom, dummyTo))
      return true;   // broker exposes no session info -> do not block
   return InTradingSession(sym);
}

// Dump the broker's trade sessions for a symbol to the log, in BOTH server
// time and Colombia time (COL = GMT-5, no DST). Called once at OnInit so the
// exact Friday close (and every day's hours) is on record without guessing.
void LogSessions(string sym)
{
   // COL = server - (server_offset_vs_gmt + 300) minutes
   int srvVsGmt = (int)((TimeCurrent() - TimeGMT()) / 60);
   int srvToCol = srvVsGmt + 300;
   LogAction("SESSIONS", StringFormat("%s server_offset_vs_gmt=%+dmin (server=GMT%+d)",
             sym, srvVsGmt, srvVsGmt / 60));
   string dn[7] = {"SUN","MON","TUE","WED","THU","FRI","SAT"};
   for (int d = 0; d < 7; d++)
   {
      datetime from, to; bool any = false; string line = "";
      for (int i = 0; ; i++)
      {
         if (!SymbolInfoSessionTrade(sym, (ENUM_DAY_OF_WEEK)d, i, from, to)) break;
         any = true;
         int fS = (int)(from / 60), tS = (int)(to / 60);
         int fC = ((fS - srvToCol) % 1440 + 1440) % 1440;
         int tC = ((tS - srvToCol) % 1440 + 1440) % 1440;
         line += StringFormat("%s#%d srv %02d:%02d-%02d:%02d / COL %02d:%02d-%02d:%02d  ",
                              (i > 0 ? "|" : ""), i, fS/60, fS%60, tS/60, tS%60,
                              fC/60, fC%60, tC/60, tC%60);
      }
      LogAction("SESSIONS", StringFormat("%s %s: %s", sym, dn[d], any ? line : "CLOSED (no sessions)"));
   }
}

// Minutes until the symbol's CURRENT session ends (-1 if not in a session,
// or session info is unavailable). Used for the pre-close basket exit.
int MinutesToSessionClose(string sym)
{
   ENUM_DAY_OF_WEEK dow;
   int now = SrvMinAndDow(dow);
   datetime from, to;
   for (int i = 0; ; i++)
   {
      if (!SymbolInfoSessionTrade(sym, dow, i, from, to)) break;
      int f = (int)(from / 60);
      int t = (int)(to / 60);
      if (now >= f && now < t) return t - now;
   }
   return -1;
}

// Hours until the symbol's NEXT trading session opens, measured from the END
// of the current session (i.e. the length of the upcoming gap). Scans forward
// day by day (up to a full week) for the first session that starts at/after
// "now". Returns a large number if none is found. This is what separates a
// weekend close (gap of many hours) from a daily rollover (gap of minutes):
// BTC reopens at 00:xx after its midnight close, gold does not reopen until
// Sunday.
double HoursToNextOpen(string sym)
{
   ENUM_DAY_OF_WEEK dow0;
   int nowMin = SrvMinAndDow(dow0);
   // Reference point on a "minutes from the start of today" timeline: the end
   // of the session we are currently in (or now, if between sessions).
   int refEnd = nowMin;
   {
      datetime f, t;
      for (int i = 0; ; i++)
      {
         if (!SymbolInfoSessionTrade(sym, dow0, i, f, t)) break;
         int fm = (int)(f / 60), tm = (int)(t / 60);
         if (nowMin >= fm && nowMin < tm) { refEnd = tm; break; }
      }
   }

   // Walk today + the next 7 days for the first session start strictly after
   // refEnd (each day d is offset by d*1440 minutes on the same timeline).
   for (int d = 0; d <= 7; d++)
   {
      int day = ((int)dow0 + d) % 7;
      datetime f, t;
      for (int i = 0; ; i++)
      {
         if (!SymbolInfoSessionTrade(sym, (ENUM_DAY_OF_WEEK)day, i, f, t)) break;
         int startAbs = (int)(f / 60) + d * 1440;
         if (startAbs > refEnd) return (startAbs - refEnd) / 60.0;
      }
   }
   return 999.0;   // no future session found -> treat as a long (weekend) gap
}

// True if the session about to close is the WEEKEND close (a multi-hour gap,
// >= WeekendGapHours) rather than an ordinary daily rollover that reopens in
// minutes. Research consensus: flatten baskets for the weekend gap, but NOT
// for the nightly rollover (blocking new entries via MarketOpen handles that).
bool IsWeekendClose(string sym)
{
   return HoursToNextOpen(sym) >= WeekendGapHours;
}

//------------------------------------------------------------------
// Server-side AutoTrading backoff. When the SERVER (not us) rejects an
// order with 10026/10027, the instrument is in a maintenance / disabled
// window (BTC's nightly window ~21:23-00:00 UTC on Exness). Without this,
// Oracle retries thousands of times per hour (16k on 2026-07-17). We park
// the symbol for a few minutes and skip it until the window clears.
//------------------------------------------------------------------
void MarkTradeBlocked(string sym, int seconds, string tag, string detail)
{
   if (seconds <= 0) return;
   int idx = Oracle_SymIndex(sym);
   if (idx < 0) return;
   bool wasBlocked = (TimeGMT() < g_oSrvBlock[idx]);
   g_oSrvBlock[idx] = TimeGMT() + seconds;
   if (!wasBlocked) LogAction(tag, detail);
}

void MarkServerBlocked(string sym)
{
   MarkTradeBlocked(sym, SrvBlockBackoffMin * 60, "SRV_BLOCK",
      StringFormat("%s: server disabled AutoTrading (retcode 10026); pausing entries %d min", sym, SrvBlockBackoffMin));
}

// 10027 is the CLIENT terminal, not the broker: this EA is not armed for trading
// (typically the seconds right after an INIT). It clears by itself, so it must not
// spend the 10-minute server backoff - the MT4 twin of this bug cost 10 minutes of
// trading after every restart (log 2026-07-20 23:24 / 07-21 00:37).
void MarkLocalBlocked(string sym)
{
   MarkTradeBlocked(sym, LocalBlockBackoffSec, "AT_LOCAL_BLOCK",
      StringFormat("%s: terminal not allowing this EA to trade yet (retcode 10027); retrying in %d s", sym, LocalBlockBackoffSec));
}

bool ServerBlocked(string sym)
{
   int idx = Oracle_SymIndex(sym);
   if (idx < 0) return false;
   return TimeGMT() < g_oSrvBlock[idx];
}

string RiskName(int r)
{
   return r >= 3 ? "VERY HIGH" : r == 2 ? "MEDIUM" : r == 1 ? "LOW" : "VERY LOW";
}

int MinutesToRiskChange()   // minutes until the current level changes
{
   int m = NowMinUTC();
   int r = HourRisk(m);
   for (int k = 1; k <= 1440; k++)
      if (HourRisk((m + k) % 1440) != r) return k;
   return 0;
}

void SetAutoTrading(bool enable)
{
   if (AutoTradingOn() == enable) return;
   long hChart = ChartGetInteger(0, CHART_WINDOW_HANDLE);
   long hMain  = GetAncestor(hChart, GA_ROOT);
   if (hMain == 0) { LogAction("ERROR", "could not get terminal window handle"); return; }
   PostMessageW(hMain, WM_COMMAND, MT5_CMD_ALGOTRADING, 0);
}

void LogAction(string action, string detail)
{
   int h = FileOpen(LogFileName, FILE_READ | FILE_WRITE | FILE_TXT | FILE_ANSI);
   if (h == INVALID_HANDLE) { Print("Cerberus LOG FAIL: ", action, " ", detail); return; }
   FileSeek(h, 0, SEEK_END);
   FileWriteString(h, TimeToString(TimeGMT(), TIME_DATE | TIME_SECONDS) + ";" + action + ";" + detail + "\r\n");
   FileClose(h);
   Print("Cerberus: ", action, " | ", detail);
}

double MarginLevelPct()
{
   double margin = AccountInfoDouble(ACCOUNT_MARGIN);
   if (margin <= 0) return 999999;
   return AccountInfoDouble(ACCOUNT_EQUITY) / margin * 100.0;
}

double AdversePips(ulong ticket)
{
   if (!PositionSelectByTicket(ticket)) return 0;
   string sym = PositionGetString(POSITION_SYMBOL);
   double pip = PipSize(sym);
   if (pip <= 0) return 0;
   long type = PositionGetInteger(POSITION_TYPE);
   if (type == POSITION_TYPE_BUY)
      return (PositionGetDouble(POSITION_PRICE_OPEN) - SymbolInfoDouble(sym, SYMBOL_BID)) / pip;
   if (type == POSITION_TYPE_SELL)
      return (SymbolInfoDouble(sym, SYMBOL_ASK) - PositionGetDouble(POSITION_PRICE_OPEN)) / pip;
   return 0;
}

bool CloseOnePosition(ulong ticket, string reason)
{
   if (!PositionSelectByTicket(ticket)) return false;
   for (int attempt = 1; attempt <= 3; attempt++)
   {
      double pl = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      if (g_trade.PositionClose(ticket))
      {
         LogAction("ORDER_CLOSED", StringFormat("#%I64u %s %.2f lots P/L=%.2f (%s)",
                   ticket, PositionGetString(POSITION_SYMBOL), PositionGetDouble(POSITION_VOLUME), pl, reason));
         return true;
      }
      int rc = (int)g_trade.ResultRetcode();
      LogAction("ORDER_CLOSE_FAIL", StringFormat("#%I64u attempt %d retcode %d", ticket, attempt, rc));
      if (rc == TRADE_RETCODE_CLIENT_DISABLES_AT || rc == TRADE_RETCODE_SERVER_DISABLES_AT)
         return false;
      Sleep(500);
      if (!PositionSelectByTicket(ticket)) return true;
   }
   return false;
}

void CloseAllOrders(string reason)
{
   ulong tickets[]; int n = 0;
   ArrayResize(tickets, PositionsTotal());
   for (int i = 0; i < PositionsTotal(); i++)
   {
      ulong tk = PositionGetTicket(i);
      if (tk > 0) tickets[n++] = tk;
   }
   for (int j = 0; j < n; j++)
      CloseOnePosition(tickets[j], reason);

   int nPend = 0;
   if (ClosePendingOrders)
   {
      ulong pend[];
      ArrayResize(pend, OrdersTotal());
      for (int i = 0; i < OrdersTotal(); i++)
      {
         ulong tk = OrderGetTicket(i);
         if (tk > 0) pend[nPend++] = tk;
      }
      for (int j = 0; j < nPend; j++)
         if (g_trade.OrderDelete(pend[j]))
            LogAction("ORDER_DELETED", StringFormat("#%I64u pending (%s)", pend[j], reason));
   }
   if (n + nPend > 0) g_lastAction = StringFormat("Closed %d orders (%s)", n + nPend, reason);
}

//==================================================================
// Lifecycle
//==================================================================
int OnInit()
{
   g_trade.SetDeviationInPoints(30);
   DeriveCurrencies();
   SchedInit();
   InitTestEvents();
   if (!LoadCacheFromDisk())
      g_feedStatus = "no cache, downloading...";
   AppendTestEvents();

   // Restore any runtime overrides a previous session set by hot command
   // (TP/grid/lot/factor/maxlev), before Oracle reads them.
   LoadOverridesFromGV();

   // Oracle strategy: resolve symbols and create the bias EMA handles
   if (!Oracle_Init())
   {
      // A wrong symbol name must NOT unload the EA silently (that is how a
      // shared build looks "dead" on another broker): keep the guardian alive
      // and put the problem on the chart where the user can read it.
      LogAction("ERROR", "Oracle_Init failed: symbol '" + Oracle_Symbols + "' not found on this broker - set Oracle_Symbols and PairsToWatch to your broker's exact names");
      Comment("CERBERUS: symbol '", Oracle_Symbols, "' not found on this broker.\n",
              "Set Oracle_Symbols (and PairsToWatch) to your broker's exact symbol name\n",
              "(e.g. XAUUSD, XAUUSD.z, GOLD) in the EA inputs and re-attach.");
   }

   // Oracle_Init already loaded the single active symbol (saved override or the
   // Oracle_Symbols default). Guarantee Rule C watches it. We deliberately do
   // NOT call ChartSetSymbolPeriod here: it is asynchronous and re-inits the EA,
   // so doing it on every startup risks a re-init loop and (if a shutdown lands
   // in that window) a corrupted .chr that loses the expert block - exactly the
   // failure that wiped the panel on 2026-07-18. The chart is aligned to the
   // traded symbol only on an explicit SYMBOL/PRESET switch (Oracle_SwitchSymbol),
   // never at init. Trading and the panel work regardless of the chart's symbol.
   string activeSym = (ArraySize(g_oSym) > 0) ? g_oSym[0] : "";
   if (activeSym != "") EnsureWatched(activeSym);

   if (!GlobalVariableCheck(GV_ORACLE)) GlobalVariableSet(GV_ORACLE, 1);

   // Sweep our own UI objects on startup, not just on exit: the OnDeinit that
   // runs on an upgrade belongs to the OUTGOING build, so anything a previous
   // version drew where this one no longer draws would linger forever.
   long ccid = ChartFirst();
   while (ccid >= 0)
   {
      ObjectsDeleteAll(ccid, "CBL_");
      ObjectsDeleteAll(ccid, "CBP_");
      ObjectsDeleteAll(ccid, "CBM_");
      ccid = ChartNext(ccid);
   }

   // Hide MT5's native trade-level lines: with a deep grid they draw dozens of
   // dotted connector lines across the chart, over the panel. Positions are
   // already shown in the panel and the ORV_ visuals, so the native ones only
   // clutter (and cover the gray panel).
   ChartSetInteger(0, CHART_SHOW_TRADE_LEVELS, false);

   PanelCreate();
   g_peakEquity = AccountInfoDouble(ACCOUNT_EQUITY);  // seed drawdown baseline
   EventSetTimer(5);
   string symList = "";
   for (int i = 0; i < ArraySize(g_oSym); i++) symList += (i > 0 ? "," : "") + g_oSym[i];
   LogAction("INIT", StringFormat("Cerberus v1.15 watching=%s currencies=%s window=-%d/+%d oracle=%s on [%s] (EMA%d %s, effective TP%.0f grid%.0f lot%.2f factor%.1f maxlot%.0f, engines %s%s)",
             PairsToWatch, JoinCurrencies(), MinutesBefore, MinutesAfter,
             OracleOn() ? "ON" : "OFF", symList, Oracle_MaPeriod, EnumToString(Oracle_TF),
             EffTP(), EffGrid(), EffLot(), EffFactor(), Oracle_MaxLot,
             Oracle_EngineA ? "A" : "-", Oracle_EngineB ? "B" : "-"));
   // Record the broker's real trade sessions (Friday close etc.) for every
   // Oracle symbol, in server AND Colombia time. No guessing the gold hours.
   for (int i = 0; i < ArraySize(g_oSym); i++) LogSessions(g_oSym[i]);
   OnTimer();
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   PanelDelete();
   long cid = ChartFirst();
   while (cid >= 0)
   {
      ObjectsDeleteAll(cid, "CBI_");
      ObjectsDeleteAll(cid, "CBL_");
      ObjectsDeleteAll(cid, "CBP_");
      cid = ChartNext(cid);
   }
   // Safety net: if the SCHEDULER (HARD mode) is the one holding AutoTrading
   // off and Cerberus is being REMOVED for good (not a restart/recompile/param
   // change), restore AT so the terminal is not left globally blocked with no
   // one to re-enable it. Do NOT do this on a restart (the window is still on
   // and the next load re-evaluates), and do NOT override a news/manual pause.
   if (reason != REASON_CHARTCHANGE && reason != REASON_PARAMETERS &&
       reason != REASON_RECOMPILE &&
       GlobalVariableCheck(GV_SCHED) && !AutoTradingOn() &&
       !GlobalVariableCheck(GV_GUARD) && !GlobalVariableCheck(GV_MANUAL))
   {
      SetAutoTrading(true);
      GlobalVariableDel(GV_SCHED);
      LogAction("AUTOTRADING_ON", "Cerberus removed -> restored AT (scheduler had it off)");
   }

   // GlobalVariables are NOT deleted: they must survive restarts
   Print(StringFormat("Cerberus ORACLE summary: baskets=%d realized=%.2f USD",
         g_oCycles, g_oRealized));
}

void OnTimer()
{
   // Log when entering/leaving a blocked hour window (the block itself is
   // applied by Oracle_OnSymbol and the panels via HourBlocked())
   static bool g_wasHourBlocked = false;
   bool hb = HourBlocked();
   if (hb != g_wasHourBlocked)
   {
      int m = NowMinUTC();
      LogAction("HOUR_WINDOW", hb
         ? StringFormat("risk %s (%02d:%02d UTC / %02d:%02d COL): ORACLE takes no entries or grid adds for %d min",
                        RiskName(HourRisk(m)), m / 60, m % 60,
                        ((m + 1140) % 1440) / 60, m % 60, MinutesToRiskChange())
         : "risk window over: ORACLE may enter again");
      g_lastAction = hb ? "Hour window: no entries" : "Hour window over";
      g_wasHourBlocked = hb;
   }
   // Log when the primary symbol's market opens/closes (broker sessions).
   static bool g_wasMktClosed = false;
   if (ArraySize(g_oSym) > 0)
   {
      bool mc = !MarketOpen(g_oSym[0]);
      if (mc != g_wasMktClosed)
      {
         LogAction("MARKET_SESSION", mc
            ? StringFormat("%s market CLOSED (broker session): no new entries/adds", g_oSym[0])
            : StringFormat("%s market OPEN: ORACLE may enter again", g_oSym[0]));
         g_lastAction = mc ? "Market closed: no entries" : "Market open";
         g_wasMktClosed = mc;
      }
   }
   ProcessCommandFile();
   RefreshFeedIfDue();
   CheckSpikePipsLive();
   CheckVolatilitySpike();
   EvaluateNewsState();
   EvaluateScheduleState();
   ApplyDefenseRules();
   // Weekend-gap protection: flatten near each symbol's session close. Needs AT
   // on to close (with AT off, close/delete fails - known trap).
   if (AutoTradingOn() && TradingPermitted())
      Oracle_PreCloseFlatten();
   // Pairs that do not tick this chart are managed by the timer (every <=5 s)
   if (AutoTradingOn() && TradingPermitted() && OracleOn())
      Oracle_OnAll();
   PanelUpdate();
   if (TimeGMT() - g_lastStatusWrite >= 30)
   {
      g_lastStatusWrite = TimeGMT();
      WriteStatusFile();
   }
}

void OnTick()
{
   CheckSpikePipsLive();
   EvaluateNewsState();
   EvaluateScheduleState();
   ApplyDefenseRules();
   // The strategy only runs with AutoTrading on (the guardian turns it off
   // on news/manual pause; with AT off every order would fail)
   if (AutoTradingOn() && TradingPermitted() && OracleOn())
      Oracle_OnAll();
   PanelUpdate();
}

//==================================================================
// GUARDIAN: watched currencies
//==================================================================
bool IsKnownCurrency(string c)
{
   return (c=="USD"||c=="EUR"||c=="GBP"||c=="JPY"||c=="AUD"||
           c=="NZD"||c=="CAD"||c=="CHF"||c=="CNY");
}

void AddCurrency(string c)
{
   if (!IsKnownCurrency(c)) return;
   for (int i = 0; i < ArraySize(g_currencies); i++)
      if (g_currencies[i] == c) return;
   int n = ArraySize(g_currencies);
   ArrayResize(g_currencies, n + 1);
   g_currencies[n] = c;
}

// Add a symbol to the volatility-watch set (g_pairs + its M1 ATR handle) if it
// is not already there. Idempotent. Called for PairsToWatch at init AND for the
// live traded symbol whenever it changes, so Rule C ALWAYS watches what we
// trade - even after a hot SYMBOL/PRESET switch, with no restart.
void EnsureWatched(string sym)
{
   if (sym == "") return;
   for (int i = 0; i < ArraySize(g_pairs); i++)
      if (g_pairs[i] == sym) return;   // already watched
   int np = ArraySize(g_pairs);
   ArrayResize(g_pairs, np + 1);
   ArrayResize(g_lastM1Bar, np + 1);
   ArrayResize(g_atrM1, np + 1);
   ArrayResize(g_volPauseSym, np + 1);
   g_pairs[np] = sym;
   g_lastM1Bar[np] = 0;
   g_volPauseSym[np] = 0;
   g_atrM1[np] = iATR(sym, PERIOD_M1, VolATRPeriod);
}

void DeriveCurrencies()
{
   string parts[];
   int n = StringSplit(PairsToWatch, ',', parts);
   for (int i = 0; i < n; i++)
   {
      string p = parts[i];
      StringTrimLeft(p); StringTrimRight(p);
      if (p == "") continue;
      EnsureWatched(p);
      StringToUpper(p);
      if (StringFind(p, "GOLD") == 0 || StringFind(p, "SILVER") == 0 ||
          StringFind(p, "PLATINUM") == 0 || StringFind(p, "PALLADIUM") == 0 ||
          StringFind(p, "XAU") == 0 || StringFind(p, "XAG") == 0 ||
          StringFind(p, "WTI") == 0 || StringFind(p, "BRENT") == 0)
      {
         AddCurrency("USD");
         continue;
      }
      if (StringLen(p) < 6) continue;
      AddCurrency(StringSubstr(p, 0, 3));
      AddCurrency(StringSubstr(p, 3, 3));
   }
}

string JoinCurrencies()
{
   string s = "";
   for (int i = 0; i < ArraySize(g_currencies); i++)
      s = s + (i > 0 ? "," : "") + g_currencies[i];
   return s;
}

bool IsWatchedCurrency(string c)
{
   for (int i = 0; i < ArraySize(g_currencies); i++)
      if (g_currencies[i] == c) return true;
   return false;
}

//==================================================================
// GUARDIAN: ForexFactory feed
//==================================================================
void RefreshFeedIfDue()
{
   datetime now = TimeGMT();
   bool due = (g_lastFeedOk == 0) || (now - g_lastFeedOk >= FeedRefreshMinutes * 60);
   bool canRetry = (now - g_lastFeedTry >= 300);
   if (!due || !canRetry) return;

   g_lastFeedTry = now;
   char data[], result[];
   string headers;
   ResetLastError();
   int status = WebRequest("GET", FEED_URL, "", 5000, data, result, headers);

   if (status == -1)
   {
      int err = GetLastError();
      g_feedStatus = "ERROR WebRequest " + IntegerToString(err);
      LogAction("FEED_ERROR", StringFormat(
         "WebRequest error %d. Add %s in Options->Expert Advisors->WebRequest", err, FEED_URL));
      return;
   }
   if (status != 200)
   {
      g_feedStatus = "HTTP " + IntegerToString(status);
      LogAction("FEED_ERROR", "HTTP " + IntegerToString(status));
      return;
   }

   string json = CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8);
   if (ParseFeed(json))
   {
      g_lastFeedOk = now;
      g_feedStatus = "OK";
      SaveCacheToDisk(json);
      AppendTestEvents();
      LogAction("FEED_OK", StringFormat("%d High events watched", g_evCount));
   }
   else
   {
      g_feedStatus = "invalid JSON";
      LogAction("FEED_ERROR", "malformed JSON; keeping previous cache");
   }
}

string GetJsonField(string chunk, string field)
{
   string key = "\"" + field + "\":\"";
   int start = StringFind(chunk, key);
   if (start < 0) return "";
   start += StringLen(key);
   int end = StringFind(chunk, "\"", start);
   if (end < 0) return "";
   return StringSubstr(chunk, start, end - start);
}

bool ParseFeed(string json)
{
   if (StringFind(json, "\"title\"") < 0 || StringFind(json, "\"impact\"") < 0)
      return false;

   string tmpTitle[MAX_EVENTS], tmpCountry[MAX_EVENTS];
   datetime tmpTime[MAX_EVENTS];
   for (int z = 0; z < MAX_EVENTS; z++) tmpTime[z] = 0;
   int count = 0;

   string items[];
   int n = StringSplit(json, '}', items);
   for (int i = 0; i < n && count < MAX_EVENTS; i++)
   {
      string chunk = items[i];
      if (StringFind(chunk, "\"title\"") < 0) continue;

      string impact  = GetJsonField(chunk, "impact");
      string country = GetJsonField(chunk, "country");
      if (impact != "High") continue;
      if (!IsWatchedCurrency(country)) continue;

      string iso = GetJsonField(chunk, "date");
      datetime t = ParseIsoToGmt(iso);
      if (t == 0) continue;

      tmpTitle[count]   = GetJsonField(chunk, "title");
      tmpCountry[count] = country;
      tmpTime[count]    = t;
      count++;
   }

   g_evCount = count;
   for (int j = 0; j < count; j++)
   {
      g_evTitle[j]   = tmpTitle[j];
      g_evCountry[j] = tmpCountry[j];
      g_evTime[j]    = tmpTime[j];
   }
   return true;
}

// "2026-07-15T08:30:00-04:00" -> epoch GMT
datetime ParseIsoToGmt(string iso)
{
   if (StringLen(iso) < 19) return 0;
   string ymd = StringSubstr(iso, 0, 4) + "." + StringSubstr(iso, 5, 2) + "." + StringSubstr(iso, 8, 2);
   string hm  = StringSubstr(iso, 11, 2) + ":" + StringSubstr(iso, 14, 2);
   int    sec = (int)StringToInteger(StringSubstr(iso, 17, 2));
   datetime local = StringToTime(ymd + " " + hm) + sec;

   int off = 0;
   string tz = StringSubstr(iso, 19);
   if (StringLen(tz) >= 6)
   {
      int sign = (StringGetCharacter(tz, 0) == '-') ? -1 : 1;
      off = sign * ((int)StringToInteger(StringSubstr(tz, 1, 2)) * 3600
                  + (int)StringToInteger(StringSubstr(tz, 4, 2)) * 60);
   }
   return local - off;
}

void SaveCacheToDisk(string json)
{
   int h = FileOpen(CACHE_FILE, FILE_WRITE | FILE_TXT | FILE_ANSI);
   if (h == INVALID_HANDLE) return;
   FileWriteString(h, json);
   FileClose(h);
}

bool LoadCacheFromDisk()
{
   if (!FileIsExist(CACHE_FILE)) return false;
   int h = FileOpen(CACHE_FILE, FILE_READ | FILE_TXT | FILE_ANSI);
   if (h == INVALID_HANDLE) return false;
   string json = "";
   while (!FileIsEnding(h))
      json += FileReadString(h);
   FileClose(h);
   if (ParseFeed(json))
   {
      g_feedStatus = "disk cache";
      LogAction("CACHE_OK", StringFormat("%d High events watched from cache", g_evCount));
      return true;
   }
   return false;
}

//==================================================================
// GUARDIAN: test events (TestEventMinutes / TEST=N)
//==================================================================
void InitTestEvents()
{
   ArrayResize(g_testTimes, 0);
   if (TestEventMinutes == "") return;
   string parts[];
   int n = StringSplit(TestEventMinutes, ',', parts);
   for (int i = 0; i < n; i++)
   {
      int mins = (int)StringToInteger(parts[i]);
      if (mins <= 0) continue;
      int k = ArraySize(g_testTimes);
      ArrayResize(g_testTimes, k + 1);
      g_testTimes[k] = TimeGMT() + mins * 60;
   }
   if (ArraySize(g_testTimes) > 0)
      LogAction("TEST_MODE", StringFormat("%d fake events injected", ArraySize(g_testTimes)));
}

void AppendTestEvents()
{
   for (int i = 0; i < ArraySize(g_testTimes) && g_evCount < MAX_EVENTS; i++)
   {
      g_evTitle[g_evCount]   = "TEST EVENT " + IntegerToString(i + 1);
      g_evCountry[g_evCount] = "USD";
      g_evTime[g_evCount]    = g_testTimes[i];
      g_evCount++;
   }
}

//==================================================================
// GUARDIAN: rule C, volatility circuit breaker
//==================================================================
void CheckVolatilitySpike()
{
   if (VolSpikeATRmult <= 0 && VolWindowATRmult <= 0 && VolSpikePips <= 0) return;
   for (int i = 0; i < ArraySize(g_pairs); i++)
   {
      string sym = g_pairs[i];
      datetime barT = iTime(sym, PERIOD_M1, 1);
      if (barT == 0 || barT == g_lastM1Bar[i]) continue;
      g_lastM1Bar[i] = barT;

      double pip = PipSize(sym);
      if (pip <= 0) continue;
      double atr = IndValue(g_atrM1[i], 1);
      if (atr <= 0) continue;
      double range = iHigh(sym, PERIOD_M1, 1) - iLow(sym, PERIOD_M1, 1);

      if (VolSpikeATRmult > 0)
      {
         if (range >= VolSpikeATRmult * atr)
         {
            VolPauseSymbol(i, StringFormat("M1 candle of %.1f pips = %.1fxATR (limit %.1fx)",
                           range / pip, range / atr, VolSpikeATRmult));
            continue;
         }
      }

      if (VolWindowATRmult > 0 && VolWindowM1Bars > 1)
      {
         int hiIdx = iHighest(sym, PERIOD_M1, MODE_HIGH, VolWindowM1Bars, 1);
         int loIdx = iLowest(sym, PERIOD_M1, MODE_LOW, VolWindowM1Bars, 1);
         if (hiIdx >= 0 && loIdx >= 0)
         {
            double winRange = iHigh(sym, PERIOD_M1, hiIdx) - iLow(sym, PERIOD_M1, loIdx);
            if (winRange >= VolWindowATRmult * atr)
               VolPauseSymbol(i, StringFormat("moved %.1f pips in %d candles = %.1fxATR (limit %.1fx)",
                              winRange / pip, VolWindowM1Bars, winRange / atr, VolWindowATRmult));
         }
      }
   }
}

// Rule C is PER SYMBOL: a spike pauses (and optionally closes) ONLY the
// affected symbol's HYBRID basket. It does not turn AutoTrading off and does
// not touch other magics (Bolt/manual): one symbol's sneeze freezes nothing else.
void VolPauseSymbol(int idx, string detail)
{
   string sym = g_pairs[idx];
   bool wasPaused = (TimeGMT() < g_volPauseSym[idx]);
   g_volPauseSym[idx] = TimeGMT() + VolPauseMinutes * 60;
   if (wasPaused) return;   // only extend the expiry, no log or closes
   LogAction("VOL_SPIKE", StringFormat("%s %s, pause %d min (only %s)",
             sym, detail, VolPauseMinutes, sym));
   g_lastAction = StringFormat("Spike on %s (local pause)", sym);
   if (CloseOnVolSpike)
      Oracle_CloseSymbol(sym);   // rule C: flush this symbol's Oracle positions
}

bool SymVolPaused(string sym)
{
   for (int i = 0; i < ArraySize(g_pairs); i++)
      if (g_pairs[i] == sym) return (TimeGMT() < g_volPauseSym[i]);
   return false;
}

// true if ANY symbol is paused (for status/panel)
bool InVolPause()
{
   for (int i = 0; i < ArraySize(g_volPauseSym); i++)
      if (TimeGMT() < g_volPauseSym[i]) return true;
   return false;
}

void CheckSpikePipsLive()
{
   if (VolSpikePips <= 0) return;
   for (int i = 0; i < ArraySize(g_pairs); i++)
   {
      string sym = g_pairs[i];
      double pip = PipSize(sym);
      if (pip <= 0) continue;
      for (int shift = 0; shift <= 1; shift++)
      {
         if (iTime(sym, PERIOD_M1, shift) == 0) continue;
         double range = iHigh(sym, PERIOD_M1, shift) - iLow(sym, PERIOD_M1, shift);
         if (range / pip < VolSpikePips) continue;
         VolPauseSymbol(i, StringFormat("M1 candle %s of %.1f pips (fixed limit %.0f)",
                        shift == 0 ? "IN PROGRESS" : "closed", range / pip, VolSpikePips));
         break;
      }
   }
}

//==================================================================
// GUARDIAN: news windows (level-based, restart-safe)
//==================================================================
bool InNewsWindow(string &eventName)
{
   datetime now = TimeGMT();
   for (int i = 0; i < g_evCount; i++)
   {
      if (now >= g_evTime[i] - MinutesBefore * 60 &&
          now <= g_evTime[i] + MinutesAfter * 60)
      {
         eventName = g_evCountry[i] + " " + g_evTitle[i];
         return true;
      }
   }
   return false;
}

void EvaluateNewsState()
{
   bool manualPause = GlobalVariableCheck(GV_MANUAL);
   string evName = "";
   bool inWindow = InNewsWindow(evName);

   if (manualPause)
   {
      if (AutoTradingOn()) SetAutoTrading(false);
      g_wasInWindow = inWindow;
      return;
   }

   // Volatility pauses are per symbol and applied by the HYBRID gates
   // (SymVolPaused). Only NEWS (the guardian's original mission) closes
   // everything and turns global AutoTrading off.
   bool shouldPause = inWindow;

   if (shouldPause)
   {
      g_activeEventName = evName;
      if (!g_wasInWindow)
         LogAction("WINDOW_ENTER", evName);
      if (AutoTradingOn())
      {
         CloseAllOrders("news: " + evName);
         SetAutoTrading(false);
         GlobalVariableSet(GV_GUARD, 1);
         LogAction("AUTOTRADING_OFF", evName);
         g_lastAction = "Paused: " + evName;
      }
   }
   else
   {
      if (g_wasInWindow)
         LogAction("WINDOW_EXIT", g_activeEventName);
      g_activeEventName = "";
      if (GlobalVariableCheck(GV_GUARD) && !AutoTradingOn())
      {
         SetAutoTrading(true);
         GlobalVariableDel(GV_GUARD);
         LogAction("AUTOTRADING_ON", "window over");
         g_lastAction = "Resumed after news";
      }
      else if (GlobalVariableCheck(GV_GUARD) && AutoTradingOn())
      {
         GlobalVariableDel(GV_GUARD);
      }
   }
   g_wasInWindow = shouldPause;
}

//------------------------------------------------------------------
// Scheduler HARD action (SchedKillAT=true): like the old AlgoGuard, on
// entering a scheduler window it closes every order and turns the GLOBAL
// AutoTrading button off; on leaving it re-enables it. When SchedKillAT is
// false this is a no-op (the soft block in Oracle_OnSymbol does the work).
//
// The lock lives in GV_SCHED - SEPARATE from news' GV_GUARD - so the two
// guardians never fight: AT is only re-enabled by whichever one turned it
// off, and never while news still wants it off. The compare is against the
// terminal's real AT state, so a mid-window restart converges with no drift.
//------------------------------------------------------------------
void EvaluateScheduleState()
{
   if (!SchedKillAT)
   {
      // Mode was switched off (or never on) but a previous HARD cycle left AT
      // down: release our lock so the button can come back. Do not fight news.
      if (GlobalVariableCheck(GV_SCHED))
      {
         if (!AutoTradingOn() && !GlobalVariableCheck(GV_GUARD) &&
             !GlobalVariableCheck(GV_MANUAL))
         {
            SetAutoTrading(true);
            LogAction("AUTOTRADING_ON", "scheduler HARD mode disabled");
         }
         GlobalVariableDel(GV_SCHED);
      }
      return;
   }

   bool blocked = SchedBlocked();

   if (blocked)
   {
      // Enter the window: close everything, then drop the global button.
      // Guarded by GV_SCHED so we act once per window, not every 5 s.
      if (!GlobalVariableCheck(GV_SCHED))
      {
         if (AutoTradingOn())
            CloseAllOrders("scheduler window");   // close BEFORE AT off (with AT off, close fails)
         SetAutoTrading(false);
         GlobalVariableSet(GV_SCHED, 1);
         LogAction("AUTOTRADING_OFF", "scheduler window (HARD)");
         g_lastAction = "Paused: scheduler window";
      }
   }
   else
   {
      // Leave the window: re-enable AT only if WE took it down and no other
      // guardian (news / manual) still wants it off.
      if (GlobalVariableCheck(GV_SCHED))
      {
         if (!GlobalVariableCheck(GV_GUARD) && !GlobalVariableCheck(GV_MANUAL) &&
             !AutoTradingOn())
         {
            SetAutoTrading(true);
            LogAction("AUTOTRADING_ON", "scheduler window over");
            g_lastAction = "Resumed after scheduler window";
         }
         GlobalVariableDel(GV_SCHED);
      }
   }
}

//==================================================================
// GUARDIAN: defense rules A/B/D/E
//==================================================================
void ApplyDefenseRules()
{
   // Without a connection (or before account data arrives after startup)
   // balance/equity come in as 0 and rule E would see a "loss" the size of
   // the baseline - false pause measured after a restart.
   if (!TerminalInfoInteger(TERMINAL_CONNECTED) ||
       AccountInfoDouble(ACCOUNT_EQUITY) <= 0 || AccountInfoDouble(ACCOUNT_BALANCE) <= 0)
      return;

   // Rule A: adverse pips limit per position
   if (MaxAdversePips > 0)
   {
      ulong tickets[]; int n = 0;
      ArrayResize(tickets, PositionsTotal());
      for (int i = 0; i < PositionsTotal(); i++)
      {
         ulong tk = PositionGetTicket(i);
         if (tk > 0) tickets[n++] = tk;
      }
      for (int j = 0; j < n; j++)
      {
         double adverse = AdversePips(tickets[j]);
         // Per-symbol limit: fixed pips with an ATR(M1) floor, so the rule
         // scales to each symbol's real volatility (300 gold pips = $30,
         // which is noise on crypto)
         double limitPips = MaxAdversePips;
         if (RuleA_xATR > 0 && PositionSelectByTicket(tickets[j]))
         {
            string rsym = PositionGetString(POSITION_SYMBOL);
            double rpip = PipSize(rsym);
            for (int q = 0; q < ArraySize(g_pairs); q++)
               if (g_pairs[q] == rsym && rpip > 0)
               {
                  double ratr = IndValue(g_atrM1[q], 1);
                  if (ratr > 0) limitPips = MathMax(limitPips, RuleA_xATR * ratr / rpip);
                  break;
               }
         }
         if (adverse >= limitPips)
         {
            LogAction("RULE_PIPS_CLOSE", StringFormat("#%I64u %.1f pips against (limit %.1f)",
                      tickets[j], adverse, limitPips));
            if (CloseOnePosition(tickets[j], "pips rule"))
               g_lastAction = StringFormat("Pips rule: closed #%I64u (%.0f pips)", tickets[j], adverse);
         }
      }
   }

   // Rule B: margin protection (close the worst until recovered)
   if (MinMarginLevelPct > 0)
   {
      for (int iter = 0; iter < 10; iter++)
      {
         if (MarginLevelPct() >= MinMarginLevelPct) break;

         ulong worstTicket = 0; double worstPL = 0;
         for (int i = 0; i < PositionsTotal(); i++)
         {
            ulong tk = PositionGetTicket(i);
            if (tk == 0) continue;
            double pl = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
            if (worstTicket == 0 || pl < worstPL) { worstTicket = tk; worstPL = pl; }
         }
         if (worstTicket == 0) break;

         LogAction("RULE_MARGIN_CLOSE", StringFormat("margin %.1f%% < %.1f%%, closing #%I64u (P/L %.2f)",
                   MarginLevelPct(), MinMarginLevelPct, worstTicket, worstPL));
         if (!CloseOnePosition(worstTicket, "margin rule")) break;
         g_lastAction = StringFormat("Margin rule: closed #%I64u", worstTicket);
      }
   }

   // Rule D: USD loss limit per position (SL backstop)
   if (MaxLossPerTradeUSD > 0)
   {
      ulong tickets2[]; int n2 = 0;
      ArrayResize(tickets2, PositionsTotal());
      for (int i2 = 0; i2 < PositionsTotal(); i2++)
      {
         ulong tk = PositionGetTicket(i2);
         if (tk > 0) tickets2[n2++] = tk;
      }
      for (int j2 = 0; j2 < n2; j2++)
      {
         if (!PositionSelectByTicket(tickets2[j2])) continue;
         double pl2 = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
         if (pl2 <= -MaxLossPerTradeUSD)
         {
            LogAction("RULE_USD_CLOSE", StringFormat("#%I64u P/L %.2f exceeds per-trade limit (%.2f)",
                      tickets2[j2], pl2, MaxLossPerTradeUSD));
            if (CloseOnePosition(tickets2[j2], "per-trade USD rule"))
               g_lastAction = StringFormat("USD rule: closed #%I64u ($%.2f)", tickets2[j2], pl2);
         }
      }
   }

   // Rule E: maximum daily loss -> close everything and pause (until RESUME)
   if (MaxDailyLossUSD > 0)
   {
      datetime today = iTime(_Symbol, PERIOD_D1, 0);
      if (!GlobalVariableCheck("NG_DayDate") || (datetime)GlobalVariableGet("NG_DayDate") != today)
      {
         GlobalVariableSet("NG_DayDate", (double)today);
         GlobalVariableSet("NG_DayStartBal", AccountInfoDouble(ACCOUNT_BALANCE));
      }
      double dayLoss = GlobalVariableGet("NG_DayStartBal") - AccountInfoDouble(ACCOUNT_EQUITY);
      if (dayLoss >= MaxDailyLossUSD && !GlobalVariableCheck(GV_MANUAL))
      {
         LogAction("RULE_DAILY_LOSS", StringFormat("day loss %.2f >= %.2f: closing everything and pausing",
                   dayLoss, MaxDailyLossUSD));
         CloseAllOrders("maximum daily loss");
         SetAutoTrading(false);
         // 2 = "the guardian paused this", vs 1 = "a human paused this". Every
         // other check only asks whether the GV exists, so both still mean
         // paused; only DoResetDay tells them apart (it may lift a rule-E pause,
         // never a human one).
         GlobalVariableSet(GV_MANUAL, 2);
         g_lastAction = StringFormat("PAUSE: daily loss $%.2f (cap %.0f)", dayLoss, MaxDailyLossUSD);
      }
   }
}

// Re-anchor the Rule E daily baseline to the current balance. Shared by the
// RESETDAY command and the panel's RESETDAY button so both behave identically.
void DoResetDay()
{
   GlobalVariableSet("NG_DayDate", (double)iTime(_Symbol, PERIOD_D1, 0));
   GlobalVariableSet("NG_DayStartBal", AccountInfoDouble(ACCOUNT_BALANCE));
   g_lastAction = StringFormat("Daily baseline re-anchored to $%.2f", AccountInfoDouble(ACCOUNT_BALANCE));
   LogAction("RESETDAY", g_lastAction);

   // Re-anchoring the day while rule E holds the pause used to leave the EA
   // silent: baseline fresh, AutoTrading still off, nothing in the log to
   // explain it (there is no error - it is paused on purpose). Only
   // ng_status.json showed it. So RESETDAY now finishes the job it implies:
   // it lifts a GUARDIAN pause (GV_MANUAL == 2). A HUMAN pause (== 1) is left
   // alone - overriding an explicit decision is not this button's business -
   // but it says so out loud instead of failing silently.
   if (!GlobalVariableCheck(GV_MANUAL)) return;
   if ((int)GlobalVariableGet(GV_MANUAL) == 1)
   {
      LogAction("WARNING", "baseline re-anchored but a MANUAL pause is still active: press RESUME (or send the RESUME command) to trade again");
      return;
   }
   GlobalVariableDel(GV_MANUAL);
   GlobalVariableDel(GV_GUARD);
   SetAutoTrading(true);
   g_lastAction = StringFormat("Day re-anchored to $%.2f + rule E pause lifted", AccountInfoDouble(ACCOUNT_BALANCE));
   LogAction("RESUME", "rule E pause lifted by RESETDAY");
}

//==================================================================
// GUARDIAN: command channel (MQL5/Files/ng_command.txt)
// AT_ON | AT_OFF | PAUSE | RESUME | CLOSEALL | RESETDAY | TEST=N |
// BUY <sym> <lots> | SELL <sym> <lots> |
// ORACLE_ON | ORACLE_OFF (open baskets keep being managed) |
// SYMON <sym> | SYMOFF <sym> | BSTOP <usd> (basket stop override; 0 = off)
//==================================================================
string ResolveSymbol(string name)
{
   if (SymbolSelect(name, true)) return name;
   string up = name; StringToUpper(up);
   for (int i = SymbolsTotal(false) - 1; i >= 0; i--)
   {
      string s = SymbolName(i, false);
      string su = s; StringToUpper(su);
      if (su == up) { SymbolSelect(s, true); return s; }
   }
   // Fuzzy fallback for broker naming (XAUUSDm vs XAUUSD vs XAUUSD.z ...):
   // walk ever-shorter prefixes of the requested name (down to 6 chars) and
   // take the first listed symbol that starts with it. Without this, a shared
   // .set made on Exness kills the EA on any other broker.
   for (int L = StringLen(up); L >= 6; L--)
   {
      string pre = StringSubstr(up, 0, L);
      for (int i = 0; i < SymbolsTotal(false); i++)
      {
         string s = SymbolName(i, false);
         string su = s; StringToUpper(su);
         if (StringFind(su, pre) == 0)
         {
            SymbolSelect(s, true);
            LogAction("SYMBOL_RESOLVED", name + " -> " + s + " (broker naming)");
            return s;
         }
      }
   }
   return name;
}

void ProcessCommandFile()
{
   if (!FileIsExist("ng_command.txt")) return;
   int h = FileOpen("ng_command.txt", FILE_READ | FILE_TXT | FILE_ANSI);
   if (h == INVALID_HANDLE) return;
   string cmd = FileReadString(h);
   FileClose(h);
   FileDelete("ng_command.txt");
   StringTrimLeft(cmd); StringTrimRight(cmd);
   string raw = cmd;
   StringToUpper(cmd);
   if (cmd == "") return;
   LogAction("COMMAND", raw);

   if (cmd == "AT_ON")       SetAutoTrading(true);
   else if (cmd == "AT_OFF") SetAutoTrading(false);
   else if (cmd == "PAUSE")
   {
      CloseAllOrders("PAUSE command");
      SetAutoTrading(false);
      GlobalVariableSet(GV_MANUAL, 1);
      g_lastAction = "Paused by command";
   }
   else if (cmd == "RESUME")
   {
      GlobalVariableDel(GV_MANUAL);
      GlobalVariableDel(GV_GUARD);
      SetAutoTrading(true);
      g_lastAction = "Resumed by command";
   }
   else if (cmd == "CLOSEALL")
      CloseAllOrders("CLOSEALL command");
   else if (cmd == "ORACLE_ON" || cmd == "ORACLE_OFF")
   {
      Oracle_SetOn(cmd == "ORACLE_ON");
      g_oLastDecision = (cmd == "ORACLE_ON") ? "ORACLE on by command" : "ORACLE off by command";
      LogAction("CMD", g_oLastDecision);
   }
   else if (StringFind(cmd, "SYMON ") == 0 || StringFind(cmd, "SYMOFF ") == 0)
   {
      string parts[];
      if (StringSplit(raw, ' ', parts) >= 2)
      {
         string sym = ResolveSymbol(parts[1]);
         if (StringFind(cmd, "SYMOFF ") == 0)
         {
            GlobalVariableSet("CB_Off_" + sym, 1);
            g_oLastDecision = sym + " turned off by command (SYMON revives)";
         }
         else
         {
            GlobalVariableDel("CB_Off_" + sym);
            g_oLastDecision = sym + " revived by command";
         }
         LogAction("ORACLE", g_oLastDecision);
      }
      else LogAction("WARNING", "syntax: SYMON <symbol> | SYMOFF <symbol>");
   }
   else if (cmd == "RESETDAY")
      DoResetDay();
   else if (StringFind(cmd, "BUY ") == 0 || StringFind(cmd, "SELL ") == 0)
   {
      string parts[];
      int n = StringSplit(raw, ' ', parts);
      if (n >= 3)
      {
         string sym = ResolveSymbol(parts[1]);
         double lots = StringToDouble(parts[2]);
         string side = parts[0]; StringToUpper(side);
         bool isBuy = (side == "BUY");
         g_trade.SetExpertMagicNumber(MAGIC_CMD);
         bool ok = isBuy ? g_trade.Buy(lots, sym, 0, 0, 0, "CB-cmd")
                         : g_trade.Sell(lots, sym, 0, 0, 0, "CB-cmd");
         if (!ok) LogAction("ERROR", StringFormat("cmd %s failed, retcode %d", cmd, (int)g_trade.ResultRetcode()));
         else LogAction("ORDER_OPENED", StringFormat("#%I64u %s by command", g_trade.ResultOrder(), cmd));
      }
      else LogAction("WARNING", "syntax: BUY <symbol> <lots>");
   }
   else if (StringFind(cmd, "TEST=") == 0)
   {
      int mins = (int)StringToInteger(StringSubstr(cmd, 5));
      if (mins > 0 && g_evCount < MAX_EVENTS)
      {
         int k = ArraySize(g_testTimes);
         ArrayResize(g_testTimes, k + 1);
         g_testTimes[k] = TimeGMT() + mins * 60;
         g_evTitle[g_evCount]   = "TEST CMD";
         g_evCountry[g_evCount] = "USD";
         g_evTime[g_evCount]    = g_testTimes[k];
         g_evCount++;
         LogAction("TEST_MODE", StringFormat("fake event by command in %d min", mins));
      }
   }
   // --- Hot config commands (no restart) --------------------------------
   else if (StringFind(cmd, "SYMBOL ") == 0)
   {
      string parts[];
      if (StringSplit(raw, ' ', parts) >= 2) Oracle_SwitchSymbol(parts[1]);
      else LogAction("WARNING", "syntax: SYMBOL <symbol>");
   }
   else if (StringFind(cmd, "SET ") == 0)
   {
      // SET TP=60 GRID=120 LOT=0.10 FACTOR=1.0 MAXLEV=0  (any subset)
      string parts[]; int np = StringSplit(raw, ' ', parts);
      for (int i = 1; i < np; i++)
      {
         string kv[]; if (StringSplit(parts[i], '=', kv) != 2) continue;
         string key = kv[0]; StringToUpper(key);
         double val = StringToDouble(kv[1]);
         if      (key == "TP")     g_ovTP     = val;
         else if (key == "GRID")   g_ovGrid   = val;
         else if (key == "LOT")    g_ovLot    = val;
         else if (key == "FACTOR") g_ovFactor = val;
         else if (key == "MAXLEV") g_ovMaxLev = (int)val;
         else LogAction("WARNING", "SET: unknown key " + key);
      }
      SaveOverridesToGV();
      // Re-anchor the shared basket TP on any open Oracle basket so a new TP
      // takes effect immediately, not only on the next add.
      if (ArraySize(g_oSym) > 0)
      {
         Oracle_SetBasketTP(g_oSym[0], MAGIC_ORACLE_A);
         Oracle_SetBasketTP(g_oSym[0], MAGIC_ORACLE_B);
      }
      g_oLastDecision = "config: " + ConfigLine();
      LogAction("SET", ConfigLine());
   }
   else if (StringFind(cmd, "PRESET ") == 0)
   {
      string parts[];
      if (StringSplit(raw, ' ', parts) >= 2) LoadPreset(parts[1]);
      else LogAction("WARNING", "syntax: PRESET <symbol>");
   }
   else if (StringFind(cmd, "BSTOP") == 0)
   {
      // BSTOP <usd>: hot basket-stop threshold, shadowing Oracle_BasketStopUSD
      // like the SET overrides (persists in GV, survives restart). BSTOP 0 = off.
      string parts[];
      if (StringSplit(raw, ' ', parts) >= 2)
      {
         g_ovBstop = StringToDouble(parts[1]);
         if (g_ovBstop < 0) g_ovBstop = 0;
         SaveOverridesToGV();
         g_oLastDecision = (EffBstop() > 0)
            ? StringFormat("basket stop = %.0f USD by command", EffBstop())
            : "basket stop OFF by command";
         LogAction("BSTOP", g_oLastDecision);
      }
      else LogAction("WARNING", "syntax: BSTOP <usd> (0 = off)");
   }
   else if (StringFind(cmd, "EMAGATE") == 0)
   {
      // EMAGATE ON|OFF: require the EMA to agree before arming a NEW basket.
      // Hot-switchable so the cadence experiment can be A/B'd without a restart.
      string parts[];
      if (StringSplit(cmd, ' ', parts) >= 2 && (parts[1] == "ON" || parts[1] == "OFF"))
      {
         g_ovEmaGate = (parts[1] == "ON") ? 1 : 0;
         SaveOverridesToGV();
         g_oLastDecision = StringFormat("new-basket EMA gate %s by command", parts[1]);
         LogAction("EMAGATE", g_oLastDecision);
      }
      else LogAction("WARNING", "syntax: EMAGATE ON|OFF");
   }
   else if (cmd == "SAVEPRESET")
      SavePreset();
   else if (cmd == "CONFIG")
      LogAction("CONFIG", ConfigLine());
   else
      LogAction("WARNING", "unknown command: " + cmd);
}

//==================================================================
// Human-readable duration from seconds: "43s" / "2m 10s" / "1h 2m".
//==================================================================
string HumanDur(int secs)
{
   if (secs < 0)    secs = 0;
   if (secs < 60)   return StringFormat("%ds", secs);
   if (secs < 3600) return StringFormat("%dm %ds", secs / 60, secs % 60);
   return StringFormat("%dh %dm", secs / 3600, (secs % 3600) / 60);
}

// is this closing deal one of Cerberus' Oracle-head trades?
bool IsCerberusCloseDeal(ulong dtk)
{
   long entry = HistoryDealGetInteger(dtk, DEAL_ENTRY);
   if (entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY) return false;
   long dtype = HistoryDealGetInteger(dtk, DEAL_TYPE);
   if (dtype != DEAL_TYPE_BUY && dtype != DEAL_TYPE_SELL) return false;
   long m = HistoryDealGetInteger(dtk, DEAL_MAGIC);
   return (m == MAGIC_ORACLE_A || m == MAGIC_ORACLE_B);
}

//==================================================================
// Tally closed Cerberus deals from the MT5 history pool. Same shape
// as OracleReporter's TallyHistory so the compare panel maps 1:1.
//==================================================================
void TallyClosedHistory(int &closed, int &wins, int &losses, double &realized,
                        int &closedToday, double &sumWin, double &sumLoss)
{
   closed = wins = losses = closedToday = 0;
   realized = sumWin = sumLoss = 0;
   datetime nowG   = TimeGMT();
   datetime dayStart = nowG - (nowG % 86400);       // 00:00 GMT today
   HistorySelect(0, nowG + 3600);
   for (int h = 0; h < HistoryDealsTotal(); h++)
   {
      ulong dtk = HistoryDealGetTicket(h);
      if (dtk == 0 || !IsCerberusCloseDeal(dtk)) continue;
      double p = HistoryDealGetDouble(dtk, DEAL_PROFIT) + HistoryDealGetDouble(dtk, DEAL_SWAP)
               + HistoryDealGetDouble(dtk, DEAL_COMMISSION);
      closed++;
      realized += p;
      if (p >= 0) { wins++;   sumWin  += p; }
      else        { losses++; sumLoss += p; }
      if ((datetime)HistoryDealGetInteger(dtk, DEAL_TIME) >= dayStart) closedToday++;
   }
}

//==================================================================
// JSON array of the last `count` closed deals, most recent first.
// Each: {type,lots,pl,dur_s,dur,close}. Duration = close - position open.
//==================================================================
string RecentClosedJson(int count)
{
   datetime nowG = TimeGMT();
   HistorySelect(0, nowG + 3600);
   ulong    picked[]; datetime pickedT[];
   ArrayResize(picked, count); ArrayResize(pickedT, count);
   int used = 0;
   for (int h = 0; h < HistoryDealsTotal(); h++)
   {
      ulong dtk = HistoryDealGetTicket(h);
      if (dtk == 0 || !IsCerberusCloseDeal(dtk)) continue;
      datetime ct = (datetime)HistoryDealGetInteger(dtk, DEAL_TIME);
      if (used < count) { picked[used] = dtk; pickedT[used] = ct; used++; }
      else
      {
         int oldest = 0;
         for (int k = 1; k < count; k++) if (pickedT[k] < pickedT[oldest]) oldest = k;
         if (ct > pickedT[oldest]) { picked[oldest] = dtk; pickedT[oldest] = ct; }
      }
   }
   // sort kept slots by close time desc
   for (int a = 0; a < used - 1; a++)
      for (int b = a + 1; b < used; b++)
         if (pickedT[b] > pickedT[a])
         {
            datetime tc = pickedT[a]; pickedT[a] = pickedT[b]; pickedT[b] = tc;
            ulong    tt = picked[a];  picked[a]  = picked[b];  picked[b]  = tt;
         }

   string arr = "";
   for (int j = 0; j < used; j++)
   {
      ulong  dtk = picked[j];
      double pl  = HistoryDealGetDouble(dtk, DEAL_PROFIT) + HistoryDealGetDouble(dtk, DEAL_SWAP)
                 + HistoryDealGetDouble(dtk, DEAL_COMMISSION);
      long   dtype = HistoryDealGetInteger(dtk, DEAL_TYPE);
      datetime ct  = (datetime)HistoryDealGetInteger(dtk, DEAL_TIME);
      // open time via the deal's position
      long posId = HistoryDealGetInteger(dtk, DEAL_POSITION_ID);
      datetime openT = ct;
      for (int k = 0; k < HistoryDealsTotal(); k++)
      {
         ulong d2 = HistoryDealGetTicket(k);
         if (d2 == 0) continue;
         if (HistoryDealGetInteger(d2, DEAL_POSITION_ID) == posId &&
             HistoryDealGetInteger(d2, DEAL_ENTRY) == DEAL_ENTRY_IN)
         { openT = (datetime)HistoryDealGetInteger(d2, DEAL_TIME); break; }
      }
      int dur = (int)(ct - openT);
      if (j > 0) arr += ",";
      arr += StringFormat("{\"type\":\"%s\",\"lots\":%.2f,\"pl\":%.2f,\"dur_s\":%d,\"dur\":\"%s\",\"close\":\"%s\"}",
             (dtype == DEAL_TYPE_BUY ? "BUY" : "SELL"),
             HistoryDealGetDouble(dtk, DEAL_VOLUME), pl, dur, HumanDur(dur),
             TimeToString(ct, TIME_DATE | TIME_MINUTES));
   }
   return arr;
}

//==================================================================
// GUARDIAN: status to disk (MQL5/Files/ng_status.json)
//==================================================================
void WriteStatusFile()
{
   string positions = "";
   int nPos = 0; double totPL = 0;
   for (int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if (ticket == 0) continue;
      long type = PositionGetInteger(POSITION_TYPE);
      double pl = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      totPL += pl;
      if (nPos > 0) positions += ",";
      positions += StringFormat("{\"ticket\":%I64u,\"type\":\"%s\",\"symbol\":\"%s\",\"lots\":%.2f,\"open\":%.2f,\"pips\":%.1f,\"pl\":%.2f,\"magic\":%d}",
                   ticket, (type == POSITION_TYPE_BUY ? "BUY" : "SELL"), PositionGetString(POSITION_SYMBOL),
                   PositionGetDouble(POSITION_VOLUME), PositionGetDouble(POSITION_PRICE_OPEN), -AdversePips(ticket), pl,
                   (int)PositionGetInteger(POSITION_MAGIC));
      nPos++;
   }

   string nextEv = "";
   datetime nowG = TimeGMT();
   int nextIdx = -1;
   for (int j = 0; j < g_evCount; j++)
      if (g_evTime[j] > nowG && (nextIdx == -1 || g_evTime[j] < g_evTime[nextIdx]))
         nextIdx = j;
   if (nextIdx >= 0)
      nextEv = StringFormat("{\"title\":\"%s\",\"country\":\"%s\",\"gmt\":\"%s\",\"minutes\":%d}",
               g_evTitle[nextIdx], g_evCountry[nextIdx],
               TimeToString(g_evTime[nextIdx], TIME_DATE | TIME_MINUTES),
               (int)((g_evTime[nextIdx] - nowG) / 60));
   else
      nextEv = "null";

   // Oracle basket state (one per symbol per engine)
   string baskets = "";
   int nBaskets = 0;
   for (int s = 0; s < ArraySize(g_oSym); s++)
   {
      int engines[2]; engines[0] = MAGIC_ORACLE_A; engines[1] = MAGIC_ORACLE_B;
      for (int e = 0; e < 2; e++)
      {
         int bn, bdir; double bLots, bAvg, bPL, bLast;
         Oracle_Basket(g_oSym[s], engines[e], bn, bdir, bLots, bAvg, bPL, bLast);
         if (bn == 0) continue;
         double pip = Oracle_Pip(g_oSym[s]);
         double btp = (bdir > 0) ? bAvg + EffTP() * pip : bAvg - EffTP() * pip;
         if (nBaskets > 0) baskets += ",";
         baskets += StringFormat("{\"symbol\":\"%s\",\"engine\":%d,\"steps\":%d,\"dir\":\"%s\",\"lots\":%.2f,\"avg\":%.5f,\"pl\":%.2f,\"tp\":%.5f}",
                    g_oSym[s], engines[e], bn,
                    (bdir > 0 ? "BUY" : "SELL"), bLots, bAvg, bPL, btp);
         nBaskets++;
      }
   }

   string evName = "";
   string status = GlobalVariableCheck(GV_MANUAL) ? "PAUSED_MANUAL"
                 : (InNewsWindow(evName) ? "PAUSED_NEWS"
                 : (GlobalVariableCheck(GV_SCHED) ? "PAUSED_SCHEDULE"
                 : (InVolPause() ? "PAUSED_VOLATILITY" : "RUNNING")));

   // closed-trade tally from the history pool (matches OracleReporter schema)
   int    cl, wn, ls, clToday; double rlz, sWin, sLoss;
   TallyClosedHistory(cl, wn, ls, rlz, clToday, sWin, sLoss);
   double winRate = (cl > 0) ? (wn * 100.0 / cl) : 0.0;
   double avgWin  = (wn > 0) ? (sWin / wn)       : 0.0;
   double avgLoss = (ls > 0) ? (sLoss / ls)      : 0.0;
   string recent  = RecentClosedJson(8);

   // peak equity + drawdown (money and pct)
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if (eq > g_peakEquity) g_peakEquity = eq;
   double ddMoney = (g_peakEquity > 0) ? (g_peakEquity - eq) : 0.0;
   double ddPct   = (g_peakEquity > 0) ? (ddMoney / g_peakEquity * 100.0) : 0.0;

   int hm = NowMinUTC();
   string primary = (ArraySize(g_oSym) > 0) ? g_oSym[0] : "";
   bool  mktOpen  = (primary == "") ? true : MarketOpen(primary);
   int   mktClose = (primary == "") ? -1  : MinutesToSessionClose(primary);
   string json = StringFormat(
      "{\"ea\":\"Cerberus\",\"version\":\"1.15\",\"gmt\":\"%s\",\"status\":\"%s\",\"hour\":{\"risk\":\"%s\",\"blocked\":%s,\"change_min\":%d,\"sched_blocked\":%s},\"market\":{\"symbol\":\"%s\",\"open\":%s,\"close_in_min\":%d},\"config\":{\"symbol\":\"%s\",\"tp\":%.0f,\"grid\":%.0f,\"lot\":%.2f,\"factor\":%.2f,\"maxlev\":%d},\"basket_stop\":{\"usd\":%.0f,\"hits_today\":%d},\"regime_blocked\":%s,\"autotrading\":%s,\"feed\":\"%s\",\"events_loaded\":%d,\"balance\":%.2f,\"equity\":%.2f,\"free_margin\":%.2f,\"margin_level\":%.1f,\"positions_pl\":%.2f,\"closed_trades\":%d,\"wins\":%d,\"losses\":%d,\"win_rate_pct\":%.1f,\"realized_pl\":%.2f,\"closed_today\":%d,\"avg_win\":%.2f,\"avg_loss\":%.2f,\"peak_equity\":%.2f,\"dd_money\":%.2f,\"dd_pct\":%.2f,\"heads\":{\"oracle\":\"%s\",\"baskets\":[%s],\"cycles\":%d,\"realized\":%.2f},\"positions\":[%s],\"recent_trades\":[%s],\"next_event\":%s,\"last_action\":\"%s\"}",
      TimeToString(nowG, TIME_DATE | TIME_SECONDS), status,
      RiskName(HourRisk(hm)), HourBlocked() ? "true" : "false", MinutesToRiskChange(),
      SchedBlocked() ? "true" : "false",
      primary, mktOpen ? "true" : "false", mktClose,
      primary, EffTP(), EffGrid(), EffLot(), EffFactor(), EffMaxLev(),
      EffBstop(), Oracle_BstopHitsToday(), g_regimeBlocked ? "true" : "false",
      AutoTradingOn() ? "true" : "false", g_feedStatus, g_evCount,
      AccountInfoDouble(ACCOUNT_BALANCE), eq, AccountInfoDouble(ACCOUNT_MARGIN_FREE),
      MarginLevelPct() >= 999999 ? 0 : MarginLevelPct(), totPL,
      cl, wn, ls, winRate, rlz, clToday, avgWin, avgLoss, g_peakEquity, ddMoney, ddPct,
      OracleOn() ? "ON" : "OFF", baskets,
      g_oCycles, g_oRealized, positions, recent, nextEv, g_lastAction);

   int h = FileOpen("ng_status.json", FILE_WRITE | FILE_TXT | FILE_ANSI);
   if (h == INVALID_HANDLE) return;
   FileWriteString(h, json);
   FileClose(h);
}

//==================================================================
// ORACLE strategy (faithful replica of Oracle 2.0; magics 7799/9977)
//==================================================================
bool OracleOn() { return !GlobalVariableCheck(GV_ORACLE) || GlobalVariableGet(GV_ORACLE) > 0; }
void Oracle_SetOn(bool on) { GlobalVariableSet(GV_ORACLE, on ? 1 : 0); }

// Strategy pip: Oracle counts 1 pip = $0.01 on XAUUSDm (Point*10 on 3/5 digits).
// This is the strategy's own scale, independent of the guardian's PipSize().
double Oracle_Pip(string sym)
{
   double pt = SymbolInfoDouble(sym, SYMBOL_POINT);
   int    dg = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   // dg 6 (crypto crosses like ETHBTCm) also uses a 10-point pip, otherwise a
   // "pip" of 1 point makes the grid/TP numbers absurdly small.
   return (dg == 3 || dg == 5 || dg == 6) ? pt * 10 : pt;
}

//------------------------------------------------------------------
// Effective (runtime-overridable) Oracle parameters. Oracle reads THESE, so a
// hot command can retune the strategy live. Each falls back to its input when
// no override is set (0 / -1 sentinel).
//------------------------------------------------------------------
double EffTP()     { return (g_ovTP     > 0) ? g_ovTP     : (double)Oracle_TakeProfit; }
double EffGrid()   { return (g_ovGrid   > 0) ? g_ovGrid   : (double)Oracle_GridSize; }
double EffLot()    { return (g_ovLot    > 0) ? g_ovLot    : Oracle_FixedLot; }
double EffFactor() { return (g_ovFactor > 0) ? g_ovFactor : Oracle_GridFactor; }
int    EffMaxLev() { return (g_ovMaxLev >= 0) ? g_ovMaxLev : Oracle_MaxGridLevels; }
double EffBstop()  { return (g_ovBstop  >= 0) ? g_ovBstop  : Oracle_BasketStopUSD; }
bool   EmaGateOn() { return (g_ovEmaGate >= 0) ? (g_ovEmaGate > 0) : Oracle_NewBasketNeedsEMA; }

// Seed overrides from any GlobalVariables a previous session persisted (so hot
// changes survive a restart). Called once at OnInit.
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

// Persist the current overrides so a restart keeps the live tuning.
void SaveOverridesToGV()
{
   if (g_ovTP     > 0) GlobalVariableSet(GV_OV_TP,     g_ovTP);
   if (g_ovGrid   > 0) GlobalVariableSet(GV_OV_GRID,   g_ovGrid);
   if (g_ovLot    > 0) GlobalVariableSet(GV_OV_LOT,    g_ovLot);
   if (g_ovFactor > 0) GlobalVariableSet(GV_OV_FACTOR, g_ovFactor);
   if (g_ovMaxLev >= 0) GlobalVariableSet(GV_OV_MAXLEV, g_ovMaxLev);
   if (g_ovBstop  >= 0) GlobalVariableSet(GV_OV_BSTOP,  g_ovBstop);
   if (g_ovEmaGate >= 0) GlobalVariableSet(GV_OV_EMAGATE, g_ovEmaGate);
}

// The active traded symbol persists in a file (a GV can't hold a string), so a
// SYMBOL command survives restart. OnInit reads it before Oracle_Init.
void SaveActiveSymbol(string sym)
{
   int h = FileOpen(ACTIVE_SYMBOL_FILE, FILE_WRITE | FILE_TXT | FILE_ANSI);
   if (h == INVALID_HANDLE) return;
   FileWriteString(h, sym);
   FileClose(h);
}
string LoadActiveSymbol()   // "" if none saved
{
   if (!FileIsExist(ACTIVE_SYMBOL_FILE)) return "";
   int h = FileOpen(ACTIVE_SYMBOL_FILE, FILE_READ | FILE_TXT | FILE_ANSI);
   if (h == INVALID_HANDLE) return "";
   string s = FileReadString(h);
   FileClose(h);
   StringTrimLeft(s); StringTrimRight(s);
   return s;
}

// Index of a symbol in the Oracle arrays, or -1.
int Oracle_SymIndex(string sym)
{
   for (int i = 0; i < ArraySize(g_oSym); i++)
      if (g_oSym[i] == sym) return i;
   return -1;
}

// Create the bias EMA handle for every Oracle symbol. Called from OnInit.
// Cerberus trades exactly ONE symbol. Priority: the saved active symbol (from
// a previous hot SYMBOL/PRESET switch), else the first entry of Oracle_Symbols.
// Single-symbol by design - no duplicates, no multi-symbol arrays to keep in
// sync (that caused an [ETHUSDm,ETHUSDm] duplicate on chart re-init).
bool Oracle_Init()
{
   string s = LoadActiveSymbol();
   if (s == "")
   {
      string parts[];
      int nSym = StringSplit(Oracle_Symbols, ',', parts);
      if (nSym > 0) { s = parts[0]; StringTrimLeft(s); StringTrimRight(s); }
   }
   s = ResolveSymbol(s);
   if (s == "") { LogAction("ERROR", "Oracle: no symbol to trade"); return false; }

   ArrayResize(g_oSym, 1);
   ArrayResize(g_oMA, 1);
   ArrayResize(g_oSrvBlock, 1);
   ArrayResize(g_oOpenedAt, 1);
   ArrayResize(g_oSawClosed, 1);
   g_oSym[0] = s;
   g_oSrvBlock[0] = 0;
   g_oOpenedAt[0] = 0;
   g_oSawClosed[0] = false;
   ENUM_MA_METHOD method = (Oracle_MaMethod == 1) ? MODE_EMA : MODE_SMA;
   g_oMA[0] = iMA(s, Oracle_TF, Oracle_MaPeriod, 0, method, PRICE_CLOSE);
   if (g_oMA[0] == INVALID_HANDLE) { LogAction("ERROR", "Oracle: invalid MA handle for " + s); return false; }
   Oracle_RegimeInitHandles(s);
   return true;
}

// H1 regime-filter handles for the active symbol (only when the filter is on).
// If a handle fails the filter fails OPEN (blocks nothing) - it is a soft veto,
// never a reason to stop trading.
void Oracle_RegimeInitHandles(string s)
{
   if (!Oracle_UseRegimeFilter) return;
   g_oADX    = iADX(s, PERIOD_H1, 14);
   g_oEMA200 = iMA(s, PERIOD_H1, 200, 0, MODE_EMA, PRICE_CLOSE);
   g_oATRH1  = iATR(s, PERIOD_H1, 14);
   if (g_oADX == INVALID_HANDLE || g_oEMA200 == INVALID_HANDLE || g_oATRH1 == INVALID_HANDLE)
      LogAction("WARNING", "regime filter: invalid H1 handle(s) for " + s + " (filter fails open)");
}

void Oracle_RegimeReleaseHandles()
{
   if (g_oADX    != INVALID_HANDLE) { IndicatorRelease(g_oADX);    g_oADX    = INVALID_HANDLE; }
   if (g_oEMA200 != INVALID_HANDLE) { IndicatorRelease(g_oEMA200); g_oEMA200 = INVALID_HANDLE; }
   if (g_oATRH1  != INVALID_HANDLE) { IndicatorRelease(g_oATRH1);  g_oATRH1  = INVALID_HANDLE; }
}

// Hot symbol switch: close every open Oracle basket, then rebuild the Oracle
// symbol arrays to the single new symbol with a fresh MA handle. Called by the
// SYMBOL command - no restart. The choice persists (SaveActiveSymbol) so it
// survives a later restart too.
bool Oracle_SwitchSymbol(string rawSym)
{
   string s = ResolveSymbol(rawSym);
   if (s == "") { LogAction("WARNING", "SYMBOL: could not resolve " + rawSym); return false; }
   if (!SymbolSelect(s, true)) { LogAction("WARNING", "SYMBOL: cannot select " + s); return false; }

   // Flatten current Oracle positions (both engines, all symbols) before switch.
   for (int i = 0; i < ArraySize(g_oSym); i++)
   {
      Oracle_CloseBasket(g_oSym[i], MAGIC_ORACLE_A, "symbol switch");
      Oracle_CloseBasket(g_oSym[i], MAGIC_ORACLE_B, "symbol switch");
   }
   // Release old indicator handles.
   for (int i = 0; i < ArraySize(g_oMA); i++)
      if (g_oMA[i] != INVALID_HANDLE) IndicatorRelease(g_oMA[i]);
   Oracle_RegimeReleaseHandles();

   // Rebuild arrays to the single new symbol.
   ArrayResize(g_oSym, 1);
   ArrayResize(g_oMA, 1);
   ArrayResize(g_oSrvBlock, 1);
   ArrayResize(g_oOpenedAt, 1);
   ArrayResize(g_oSawClosed, 1);
   g_oSym[0] = s;
   g_oSrvBlock[0] = 0;
   g_oOpenedAt[0] = 0;
   g_oSawClosed[0] = false;
   ENUM_MA_METHOD method = (Oracle_MaMethod == 1) ? MODE_EMA : MODE_SMA;
   g_oMA[0] = iMA(s, Oracle_TF, Oracle_MaPeriod, 0, method, PRICE_CLOSE);
   if (g_oMA[0] == INVALID_HANDLE) { LogAction("ERROR", "SYMBOL: invalid MA handle for " + s); return false; }
   Oracle_RegimeInitHandles(s);

   EnsureWatched(s);   // Rule C must watch the symbol we now trade (no restart)
   g_oBstopUntil[0] = 0; g_oBstopUntil[1] = 0;   // cooldowns belong to the old symbol's move
   SaveActiveSymbol(s);
   g_oLastDecision = "switched to " + s;
   LogAction("SYMBOL", "now trading " + s + " (basket flattened, volatility-watched)");

   // Move the CHART to the traded symbol so the basket visuals (Oracle_DrawChart
   // only draws when _Symbol == the traded symbol) render on the right chart.
   // MUST be the LAST action here: ChartSetSymbolPeriod is ASYNC and queues an
   // EA re-init. OnInit re-loads the saved active symbol (SaveActiveSymbol above)
   // and, crucially, does NOT call ChartSetSymbolPeriod again - so this fires
   // exactly once, no loop. WARNING: never close/restart the terminal in the
   // seconds right after a SYMBOL/PRESET - the queued re-init colliding with a
   // shutdown can save a .chr without the expert block (panel lost, 2026-07-18).
   if (ChartSymbol(0) != s)
      ChartSetSymbolPeriod(0, s, Oracle_TF);
   return true;
}

// Current effective config as a compact string, for logs/panel/presets.
string ConfigLine()
{
   string sym = (ArraySize(g_oSym) > 0) ? g_oSym[0] : "-";
   return StringFormat("%s TP=%.0f GRID=%.0f LOT=%.2f FACTOR=%.2f MAXLEV=%d EMAGATE=%s",
                       sym, EffTP(), EffGrid(), EffLot(), EffFactor(), EffMaxLev(),
                       EmaGateOn() ? "ON" : "OFF");
}

// --- Presets: one line per symbol in symbol_presets.txt ------------------
//     SYMBOL=TP,GRID,LOT,FACTOR,MAXLEV[,BSTOP]  (e.g. ETHUSDm=60,300,0.10,1.0,15,20)
// SAVEPRESET writes the current config under the active symbol; PRESET <sym>
// loads a symbol's line, applies it AND switches to that symbol. BSTOP is the
// 6th field so each symbol keeps its own basket stop (a $20 stop sized for ETH
// baskets is disproportionate for gold's 0.01-lot baskets); old 5-field lines
// leave the current basket stop untouched.
void SavePreset()
{
   if (ArraySize(g_oSym) == 0) return;
   string sym = g_oSym[0];
   string newLine = StringFormat("%s=%.0f,%.0f,%.2f,%.2f,%d,%.2f",
                    sym, EffTP(), EffGrid(), EffLot(), EffFactor(), EffMaxLev(), EffBstop());
   // Read existing lines, replace the one for this symbol (or append).
   string keep[]; int nk = 0;
   if (FileIsExist(PRESETS_FILE))
   {
      int rh = FileOpen(PRESETS_FILE, FILE_READ | FILE_TXT | FILE_ANSI);
      if (rh != INVALID_HANDLE)
      {
         while (!FileIsEnding(rh))
         {
            string ln = FileReadString(rh);
            StringTrimLeft(ln); StringTrimRight(ln);
            if (ln == "") continue;
            if (StringFind(ln, sym + "=") == 0) continue;   // drop old entry for this sym
            ArrayResize(keep, nk + 1); keep[nk++] = ln;
         }
         FileClose(rh);
      }
   }
   int wh = FileOpen(PRESETS_FILE, FILE_WRITE | FILE_TXT | FILE_ANSI);
   if (wh == INVALID_HANDLE) { LogAction("WARNING", "SAVEPRESET: cannot write file"); return; }
   for (int i = 0; i < nk; i++) FileWriteString(wh, keep[i] + "\r\n");
   FileWriteString(wh, newLine + "\r\n");
   FileClose(wh);
   LogAction("SAVEPRESET", newLine);
}

bool LoadPreset(string rawSym)
{
   string sym = ResolveSymbol(rawSym);
   if (!FileIsExist(PRESETS_FILE)) { LogAction("WARNING", "PRESET: no " + PRESETS_FILE); return false; }
   int rh = FileOpen(PRESETS_FILE, FILE_READ | FILE_TXT | FILE_ANSI);
   if (rh == INVALID_HANDLE) return false;
   string found = "";
   while (!FileIsEnding(rh))
   {
      string ln = FileReadString(rh);
      StringTrimLeft(ln); StringTrimRight(ln);
      if (StringFind(ln, sym + "=") == 0) { found = ln; break; }
   }
   FileClose(rh);
   if (found == "") { LogAction("WARNING", "PRESET: no entry for " + sym); return false; }

   string kv[]; StringSplit(found, '=', kv);
   if (ArraySize(kv) < 2) return false;
   string v[]; int nv = StringSplit(kv[1], ',', v);   // TP,GRID,LOT,FACTOR,MAXLEV[,BSTOP]
   if (nv >= 1 && StringToDouble(v[0]) > 0) g_ovTP     = StringToDouble(v[0]);
   if (nv >= 2 && StringToDouble(v[1]) > 0) g_ovGrid   = StringToDouble(v[1]);
   if (nv >= 3 && StringToDouble(v[2]) > 0) g_ovLot    = StringToDouble(v[2]);
   if (nv >= 4 && StringToDouble(v[3]) > 0) g_ovFactor = StringToDouble(v[3]);
   if (nv >= 5)                             g_ovMaxLev = (int)StringToInteger(v[4]);
   if (nv >= 6)                             g_ovBstop  = MathMax(0, StringToDouble(v[5]));  // 0 = off; absent = keep current
   SaveOverridesToGV();
   Oracle_SwitchSymbol(sym);
   LogAction("PRESET", "loaded " + found + " -> " + ConfigLine());
   return true;
}

// Direction bias: +1 BUY, -1 SELL, 0 none. Oracle's HILO is the Gann HiLo
// Activator - a TREND indicator that always gives a side, not a rare breakout.
// It compares the last close against the SMA of the previous N highs (for the
// down-flip) and the SMA of the previous N lows (for the up-flip):
//   close > SMA(highs, N)  -> uptrend  -> BUY
//   close < SMA(lows,  N)  -> downtrend-> SELL
//   in between: keep the previous side (persists the trend).
// The EMA(34) is a confirming filter: only take the HiLo side that agrees with
// price-vs-EMA. This gives a continuous direction (why Oracle trades often),
// not the near-never breakout the old code required.
int Oracle_Bias(int idx)
{
   string sym  = g_oSym[idx];
   double ma   = IndValue(g_oMA[idx], 1);
   double close = iClose(sym, Oracle_TF, 1);
   if (ma == 0 || close == 0) return 0;

   int N = Oracle_HILOPeriod;
   double sumHi = 0, sumLo = 0;
   for (int k = 1; k <= N; k++)   // previous N bars (from the closed bar back)
   {
      sumHi += iHigh(sym, Oracle_TF, k);
      sumLo += iLow (sym, Oracle_TF, k);
   }
   double hiAvg = sumHi / N;   // Gann HiLo up-band
   double loAvg = sumLo / N;   // Gann HiLo down-band

   // HiLo Activator side (persist previous side when price is inside the band).
   // This ALWAYS carries a direction once started - that is Oracle's continuous
   // signal, why it trades often. We do NOT gate it with the slow EMA34: on M1
   // the fast HiLo and slow EMA disagree constantly, and requiring both killed
   // every entry (bias=0). The EMA stays available as a soft tie-breaker only
   // when the HiLo has no side yet (very first bars).
   static int hiloSide[]; ArrayResize(hiloSide, ArraySize(g_oSym));
   if (close > hiAvg)      hiloSide[idx] = 1;    // flipped up   -> BUY
   else if (close < loAvg) hiloSide[idx] = -1;   // flipped down -> SELL
   int hilo = hiloSide[idx];
   if (Oracle_HILOInvert) hilo = -hilo;

   if (hilo != 0) return hilo;                   // HiLo side is the signal
   return (close < ma) ? -1 : (close > ma ? 1 : 0);  // start-up fallback: EMA side
}

// Price vs EMA side (+1 above / -1 below / 0 flat-or-no-data). Only used by the
// EMAGATE experiment: it decides whether a NEW basket may arm, never an add.
int Oracle_EmaSide(int idx)
{
   double ma    = IndValue(g_oMA[idx], 1);
   double close = iClose(g_oSym[idx], Oracle_TF, 1);
   if (ma == 0 || close == 0) return 0;
   return (close > ma) ? 1 : (close < ma ? -1 : 0);
}

// Walk one engine's basket for a symbol: count, dir (+1/-1), total lots,
// weighted-avg open price, floating P/L, and the most-recent open price.
void Oracle_Basket(string sym, int magic, int &n, int &dir, double &lots,
                   double &avg, double &pl, double &lastPrice)
{
   n = 0; dir = 0; lots = 0; avg = 0; pl = 0; lastPrice = 0;
   double wsum = 0, loPrice = 0, hiPrice = 0;
   for (int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if (!PositionSelectByTicket(tk)) continue;
      if (PositionGetString(POSITION_SYMBOL) != sym) continue;
      if ((int)PositionGetInteger(POSITION_MAGIC) != magic) continue;
      double vol = PositionGetDouble(POSITION_VOLUME);
      double op  = PositionGetDouble(POSITION_PRICE_OPEN);
      n++; lots += vol; wsum += op * vol;
      pl += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      dir = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
      // Track the price extremes of the basket. The grid must add the next level
      // a full GridSize BEYOND the deepest level reached, not beyond whichever
      // level was opened last in time: with second-resolution POSITION_TIME and
      // price rebounds, the newest-by-time level is often NOT the extreme, which
      // let adds stack pips apart and violate the GridSize gate (measured
      // 2026-07-20: 17/20 adds inside the gate, a basket at 21 levels instead of
      // ~4). The anchor is the basket low for a BUY grid, the high for a SELL.
      if (loPrice == 0 || op < loPrice) loPrice = op;
      if (hiPrice == 0 || op > hiPrice) hiPrice = op;
   }
   if (lots > 0) avg = wsum / lots;
   if (n > 0) lastPrice = (dir > 0) ? loPrice : hiPrice;
}

// Current spread in points (broker points, matching InpMaxSpread's unit).
double Oracle_SpreadPoints(string sym)
{
   double pt = SymbolInfoDouble(sym, SYMBOL_POINT);
   if (pt <= 0) return 0;
   double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
   double bid = SymbolInfoDouble(sym, SYMBOL_BID);
   return (ask - bid) / pt;
}

// Open one Oracle level for an engine. dir +1 BUY / -1 SELL. `level` scales
// the lot by GridFactor^level. NO individual TP: Oracle manages exit at the
// BASKET level (see Oracle_OnSymbol) - it closes the whole basket when the
// weighted average reaches +TP, confirmed live (4 orders closing at one price).
void Oracle_Open(string sym, int magic, int dir, int level)
{
   g_trade.SetExpertMagicNumber(magic);
   double lot = EffLot() * MathPow(EffFactor(), level);
   double step = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   if (step > 0) lot = MathFloor(lot / step + 0.0000001) * step;
   double vmin = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   if (lot < vmin) lot = vmin;

   bool ok = (dir > 0)
      ? g_trade.Buy(lot, sym, 0.0, 0.0, 0.0, "Oracle")
      : g_trade.Sell(lot, sym, 0.0, 0.0, 0.0, "Oracle");
   if (ok)
      g_oLastDecision = StringFormat("%s %s %.2f L%d (eng %d)",
                        (dir > 0 ? "BUY" : "SELL"), sym, lot, level, magic);
   else
   {
      int rc = (int)g_trade.ResultRetcode();
      // Back off instead of hammering retries every tick/timer cycle, but keep the
      // two causes apart: 10026 = the SERVER disabled AutoTrading (only the broker
      // clears it -> minutes), 10027 = the CLIENT terminal has not armed this EA
      // (clears by itself -> seconds).
      if (rc == 10026)      MarkServerBlocked(sym);
      else if (rc == 10027) MarkLocalBlocked(sym);
      else LogAction("ORACLE", StringFormat("%s open FAILED retcode %d", sym, rc));
   }
}

// Close the whole basket of one engine on a symbol (basket TP or rule C).
// Returns true only when EVERY level was actually closed, so a caller like the
// basket stop can tell a real cut from an announced-but-failed one.
bool Oracle_CloseBasket(string sym, int magic, string reason)
{
   double booked = 0;
   bool allOk = true;
   for (int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if (!PositionSelectByTicket(tk)) continue;
      if (PositionGetString(POSITION_SYMBOL) != sym) continue;
      if ((int)PositionGetInteger(POSITION_MAGIC) != magic) continue;
      double lvl = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      if (CloseOnePosition(tk, reason)) booked += lvl;
      else allOk = false;
   }
   if (booked != 0) { g_oRealized += booked; g_oCycles++; }
   return allOk;
}

// Close every Oracle position on a symbol (both engines). Rule C spike helper.
void Oracle_CloseSymbol(string sym)
{
   Oracle_CloseBasket(sym, MAGIC_ORACLE_A, "Oracle rule C spike");
   Oracle_CloseBasket(sym, MAGIC_ORACLE_B, "Oracle rule C spike");
}

// Pre-close weekend-gap protection: a few minutes before each symbol's
// session closes, flatten its baskets so we do not carry exposure across the
// weekend (or a broker holiday) into the Sunday open gap. Broker-driven, so it
// fires on the real Friday close regardless of server DST/offset.
void Oracle_PreCloseFlatten()
{
   if (!UseSessionFilter || PreCloseCloseMin <= 0) return;
   for (int i = 0; i < ArraySize(g_oSym); i++)
   {
      string sym = g_oSym[i];
      if (SymClass(sym) == 2) continue;   // crypto trades through the weekend - no gap to protect (ETHUSDm was flattened 60x on Friday 23:5x, -$15 churn, 2026-07-18)
      if (ServerBlocked(sym)) continue;   // server rejects closes too - don't loop
      int left = MinutesToSessionClose(sym);
      if (left < 0 || left > PreCloseCloseMin) continue;   // not near a close
      // Research consensus: flatten for the WEEKEND gap only. The nightly
      // rollover reopens in minutes - closing then would just churn healthy
      // cycles and book floating P/L; MarketOpen() already blocks new entries
      // during it. PreCloseWeekendOnly=false reverts to closing on every close.
      if (PreCloseWeekendOnly && !IsWeekendClose(sym)) continue;
      // Only act if there is actually something open on this symbol.
      int nA, nB, d; double lo, av, pl, la;
      Oracle_Basket(sym, MAGIC_ORACLE_A, nA, d, lo, av, pl, la);
      Oracle_Basket(sym, MAGIC_ORACLE_B, nB, d, lo, av, pl, la);
      if (nA == 0 && nB == 0) continue;
      LogAction("PRECLOSE_FLATTEN",
                StringFormat("%s session closes in %d min: flattening baskets (weekend-gap protection)", sym, left));
      Oracle_CloseBasket(sym, MAGIC_ORACLE_A, "pre-close weekend-gap protection");
      Oracle_CloseBasket(sym, MAGIC_ORACLE_B, "pre-close weekend-gap protection");
   }
}

// True while sym is inside the pre-close flatten window. Entries/adds must be
// vetoed here too, or the flatten and a fresh Oracle entry chase each other
// every timer tick until the session actually closes (131 churn closes on
// ETHUSDm inside one 5-minute window, 2026-07-18). Mirrors the conditions of
// Oracle_PreCloseFlatten exactly.
bool Oracle_PreCloseBlocked(string sym)
{
   if (!UseSessionFilter || PreCloseCloseMin <= 0) return false;
   if (SymClass(sym) == 2) return false;               // crypto never pre-closes
   int left = MinutesToSessionClose(sym);
   if (left < 0 || left > PreCloseCloseMin) return false;
   return !PreCloseWeekendOnly || IsWeekendClose(sym);
}

// Market closed, or open for less than Oracle_OpenWarmupMin minutes. Replaces
// the bare !MarketOpen() check in the entry gate: right after a session
// (re)open - the Sunday bell and the daily 22:00 GMT rollover resume - quotes
// are thin and spreads wide, and a fake first candle can trip the ATR-relative
// rule C. Soft veto, twin of the hour filter: never closes anything. The
// closed->open transition is tracked at runtime, so no session-table parsing;
// crypto (never closed) never arms it.
bool Oracle_ClosedOrWarmingUp(int idx)
{
   string sym = g_oSym[idx];
   if (!MarketOpen(sym)) { g_oSawClosed[idx] = true; return true; }
   if (g_oSawClosed[idx])
   {
      g_oSawClosed[idx] = false;
      g_oOpenedAt[idx]  = TimeCurrent();
      if (Oracle_OpenWarmupMin > 0)
         LogAction("OPEN_WARMUP", StringFormat("%s: session reopened, entries vetoed %d min", sym, Oracle_OpenWarmupMin));
   }
   return (Oracle_OpenWarmupMin > 0 && g_oOpenedAt[idx] > 0 &&
           TimeCurrent() - g_oOpenedAt[idx] < Oracle_OpenWarmupMin * 60);
}

// Apply ONE common take-profit to EVERY position of a basket, on the server -
// exactly how Oracle does it (all grid orders share the same T/P price, seen
// live). The target is the weighted average +/- TP pips, in the basket's
// favour. Called after each open so a new level re-anchors the whole basket's
// TP to the new average. The broker then closes all of them together when hit.
void Oracle_SetBasketTP(string sym, int magic)
{
   int n, dir; double lots, avg, pl, last;
   Oracle_Basket(sym, magic, n, dir, lots, avg, pl, last);
   if (n == 0 || avg == 0) return;

   double pip = Oracle_Pip(sym);
   int    dg  = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   double tp  = (dir > 0) ? NormalizeDouble(avg + EffTP() * pip, dg)
                          : NormalizeDouble(avg - EffTP() * pip, dg);

   // Keep the TP outside the broker's minimum stops distance from the market,
   // or PositionModify is rejected and the basket never gets a server TP.
   double point   = SymbolInfoDouble(sym, SYMBOL_POINT);
   double minDist = SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL) * point;
   double bidNow  = SymbolInfoDouble(sym, SYMBOL_BID);
   double askNow  = SymbolInfoDouble(sym, SYMBOL_ASK);
   if (dir > 0 && tp < bidNow + minDist) tp = NormalizeDouble(bidNow + minDist + point, dg);
   if (dir < 0 && tp > askNow - minDist) tp = NormalizeDouble(askNow - minDist - point, dg);

   // Server-side SL, sized so the basket losing ALL its lots at once approximates
   // the basket stop: distance = BasketStopUSD / (lots * tick value per pip), off
   // the CURRENT average (not the open price), so it re-anchors as the grid adds
   // levels - exactly like the TP above. This is a backstop for when our own
   // close orders get rejected mid-move (measured 2026-07-20: the basket stop
   // fired on time but the server refused every retry for ~2h while price kept
   // running, costing far more than the configured stop). The broker executes a
   // server SL itself; it does not depend on our terminal getting an order through.
   double slPx = 0;
   if (Oracle_UseServerSL && EffBstop() > 0 && lots > 0)
   {
      double tickVal  = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
      double tickSize = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
      if (tickVal > 0 && tickSize > 0)
      {
         double pxDist = (EffBstop() / lots) * (tickSize / tickVal);
         slPx = (dir > 0) ? NormalizeDouble(avg - pxDist, dg) : NormalizeDouble(avg + pxDist, dg);
         if (dir > 0 && slPx > bidNow - minDist) slPx = NormalizeDouble(bidNow - minDist - point, dg);
         if (dir < 0 && slPx < askNow + minDist) slPx = NormalizeDouble(askNow + minDist + point, dg);
         if (slPx <= 0 || (dir > 0 && slPx >= avg) || (dir < 0 && slPx <= avg)) slPx = 0;  // sanity: never past the average
      }
   }

   for (int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if (!PositionSelectByTicket(tk)) continue;
      if (PositionGetString(POSITION_SYMBOL) != sym) continue;
      if ((int)PositionGetInteger(POSITION_MAGIC) != magic) continue;
      bool tpStale = MathAbs(PositionGetDouble(POSITION_TP) - tp) >= pip * 0.1;
      bool slStale = (slPx > 0) && MathAbs(PositionGetDouble(POSITION_SL) - slPx) >= pip * 0.1;
      if (!tpStale && !slStale) continue;
      g_trade.PositionModify(tk, slPx, tp);
   }
}

// H1 regime veto (soft, twin of HourBlocked): never closes anything, only
// blocks NEW entries and grid adds against a strong H1 trend. Blocked when
// ADX(14) H1 > threshold with the DI direction contrary to the signal, or when
// price sits further than RegimeATRDist x ATR(14) H1 beyond the EMA200 on the
// side the signal would fade. Reads the last CLOSED H1 bar (shift 1) so the
// verdict does not flicker intrabar. Fails open on any handle/buffer problem.
bool Oracle_RegimeBlocked(int dirSig)
{
   if (!Oracle_UseRegimeFilter || dirSig == 0) return false;
   double adx = IndValueBuf(g_oADX, 0, 1);
   double dip = IndValueBuf(g_oADX, 1, 1);
   double dim = IndValueBuf(g_oADX, 2, 1);
   bool contrary = (adx > Oracle_RegimeADX) &&
                   ((dirSig > 0) ? (dim > dip) : (dip > dim));
   bool extended = false;
   double dist = 0;
   if (Oracle_RegimeATRDist > 0)
   {
      double ema = IndValue(g_oEMA200, 1);
      double atr = IndValue(g_oATRH1, 1);
      double bid = SymbolInfoDouble(g_oSym[0], SYMBOL_BID);
      if (ema > 0 && atr > 0)
      {
         dist = (bid - ema) / atr;
         extended = (dirSig > 0) ? (dist <= -Oracle_RegimeATRDist)
                                 : (dist >=  Oracle_RegimeATRDist);
      }
   }
   bool blocked = contrary || extended;
   if (blocked != g_regimeBlocked)   // log the transition only, like the hour filter
   {
      g_regimeBlocked = blocked;
      LogAction("REGIME_BLOCK", StringFormat("%s %s for %s: ADX=%.1f DI+=%.1f DI-=%.1f dist=%.2fxATR",
                g_oSym[0], blocked ? "ON" : "off", (dirSig > 0 ? "BUY" : "SELL"),
                adx, dip, dim, dist));
   }
   return blocked;
}

// Basket-stop bookkeeping. Engine index for the per-engine cooldown array, and
// a daily hit counter for the status JSON (rolls over with the UTC date).
int Oracle_EngineIdx(int magic) { return (magic == MAGIC_ORACLE_A) ? 0 : 1; }

void Oracle_BstopMarkHit()
{
   MqlDateTime dt; TimeToStruct(TimeGMT(), dt);
   int day = dt.year * 1000 + dt.day_of_year;
   if (day != g_oBstopDay) { g_oBstopDay = day; g_oBstopHits = 0; }
   g_oBstopHits++;
}

int Oracle_BstopHitsToday()
{
   MqlDateTime dt; TimeToStruct(TimeGMT(), dt);
   return (dt.year * 1000 + dt.day_of_year == g_oBstopDay) ? g_oBstopHits : 0;
}

// Effective grid depth cap per engine. Uses the DECLARED capital (Oracle_
// BaseCapital), not the live balance, so the cap is stable and does not drift
// as the P/L moves. Homologated across account sizes: $1k->5, $4k->22 at the
// default $180/level - the same proportional risk Oracle takes on its $4k.
// Returns the tighter of the absolute and proportional caps that are enabled.
int Oracle_EffectiveMaxLevels()
{
   int cap = 100000;   // effectively "no depth cap" fallback (MaxLot still applies)
   if (EffMaxLev() > 0)
      cap = EffMaxLev();
   if (Oracle_DollarsPerLevel > 0 && Oracle_BaseCapital > 0)
   {
      int prop = (int)MathFloor(Oracle_BaseCapital / Oracle_DollarsPerLevel);
      if (prop < 1) prop = 1;                 // always allow at least the first add
      if (prop < cap) cap = prop;             // take the tighter cap
   }
   return cap;
}

// One engine's logic for one symbol. Oracle puts a COMMON server-side TP on the
// whole basket (average +/- TP pips) and lets the broker close all together;
// adding a level re-anchors that TP to the new average. We only decide entries
// and grid adds here, then (re)set the shared TP. A depth cap bounds the grid.
void Oracle_OnSymbol(int idx, int magic)
{
   string sym = g_oSym[idx];

   int n, dir; double lots, avg, pl, last;
   Oracle_Basket(sym, magic, n, dir, lots, avg, pl, last);
   double pip = Oracle_Pip(sym);
   if (pip <= 0) return;
   double bid = SymbolInfoDouble(sym, SYMBOL_BID);

   // Keep the shared basket TP in sync (covers restarts / partial fills too).
   if (n > 0) Oracle_SetBasketTP(sym, magic);

   // No connection (or account data not in yet after startup): every order
   // would fail with 10031 and flood the journal 5s at a time. Skip entries
   // until the terminal is back on the server - same guard ApplyDefenseRules
   // uses. Managing the existing basket TP above is fine offline (it only
   // queues a modify), but opening/adding is not.
   if (!TerminalInfoInteger(TERMINAL_CONNECTED) ||
       AccountInfoDouble(ACCOUNT_EQUITY) <= 0 || AccountInfoDouble(ACCOUNT_BALANCE) <= 0)
      return;

   // ORACLE basket stop: cut THIS engine's whole basket when its floating loss
   // reaches the effective threshold. An earlier, per-basket sibling of rule D
   // (per position) and rule E (per day) - it does not touch the other engine.
   // Placed BEFORE the soft blocks below so a blocked hour cannot delay the cut.
   if (n > 0 && EffBstop() > 0 && pl <= -EffBstop())
   {
      LogAction("BASKET_STOP", StringFormat("%s magic %d: floating %.2f <= -%.2f, cutting %d levels (%.2f lots)",
                sym, magic, pl, EffBstop(), n, lots));
      // Only SPEND the stop (hit counter + cooldown) if the cut really happened.
      // Marking it on a failed close would leave the basket running with its stop
      // already used up (the MT4 twin did exactly that on err 136, 2026-07-21).
      if (!Oracle_CloseBasket(sym, magic, "basket stop"))
      {
         LogAction("BASKET_STOP_FAIL", StringFormat("%s magic %d: cut incomplete, retrying next pass", sym, magic));
         return;
      }
      Oracle_BstopMarkHit();
      if (Oracle_BasketStopCooldownMin > 0)
         g_oBstopUntil[Oracle_EngineIdx(magic)] = TimeGMT() + Oracle_BasketStopCooldownMin * 60;
      return;
   }

   // Respect the guardian for NEW entries/adds.
   if (HourBlocked() || SchedBlocked() || SymVolPaused(sym) || Oracle_ClosedOrWarmingUp(idx) || ServerBlocked(sym) || Oracle_PreCloseBlocked(sym)) return;

   bool spreadOK = (Oracle_MaxSpread <= 0) || (Oracle_SpreadPoints(sym) <= Oracle_MaxSpread);

   if (n == 0)
   {
      if (TimeGMT() < g_oBstopUntil[Oracle_EngineIdx(magic)]) return;   // basket-stop cooldown: no new basket inside the same move
      if (!spreadOK) return;
      int bias = Oracle_Bias(idx);
      // Homologation to the MT4 original: with BOTH engines on, each owns ONE
      // side - A (7799) opens only BUY signals, B (9977) only SELL - and both
      // ladders can coexist on the hedging account (Oracle 2.0's own input
      // literal: "if all the engines are disabled runs a motor in buy and
      // sell"; its 2026-07-17 log shows simultaneous buy+sell ladders and
      // never same-side duplicates). With a single engine on, that engine
      // keeps trading both sides, one at a time.
      int side = 0;
      if (Oracle_EngineA && Oracle_EngineB) side = (magic == MAGIC_ORACLE_A) ? 1 : -1;
      if (bias == 0 || (side != 0 && bias != side)) return;
      // EMAGATE: the HiLo alone always carries a side, so a closed basket re-arms
      // instantly. Requiring the EMA to agree gates only the NEW basket (adds keep
      // using the HiLo direction), which is the one difference measured against
      // Oracle 2.0's cadence on 2026-07-21.
      if (EmaGateOn() && Oracle_EmaSide(idx) != bias) return;
      if (Oracle_RegimeBlocked(bias)) return;   // do not arm a grid against a strong H1 trend
      Oracle_Open(sym, magic, bias, 0);
      g_oLastAddTime[Oracle_EngineIdx(magic)] = TimeCurrent();   // throttle the first add too
      Oracle_SetBasketTP(sym, magic);
      return;
   }

   // Grid: add level n on an adverse GridSize move, capped by the effective
   // depth limit (proportional to balance so risk is the same on any account).
   bool depthOK = (n < Oracle_EffectiveMaxLevels());
   double adverse = (dir < 0) ? (bid - last) : (last - bid);
   double nextLot = EffLot() * MathPow(EffFactor(), n);
   // Throttle: OnTimer and OnTick both run this, so without a minimum gap a burst
   // of ticks in the same second adds several levels before the fresh order is
   // visible in PositionsTotal - the second add then measures against a stale
   // extreme and stacks pips apart, violating GridSize (measured 2026-07-21:
   // levels $0.06 apart against a $0.30 gate). One add per Oracle_MinSecsBetweenAdds.
   int ei2 = Oracle_EngineIdx(magic);
   bool addThrottled = (Oracle_MinSecsBetweenAdds > 0 &&
                        TimeCurrent() - g_oLastAddTime[ei2] < Oracle_MinSecsBetweenAdds);
   if (spreadOK && depthOK && !addThrottled && !Oracle_RegimeBlocked(dir) &&
       adverse >= EffGrid() * pip && (lots + nextLot) <= Oracle_MaxLot)
   {
      Oracle_Open(sym, magic, dir, n);
      g_oLastAddTime[ei2] = TimeCurrent();
      Oracle_SetBasketTP(sym, magic);   // re-anchor the shared TP to the new average
   }
}

// Run both engines over all symbols.
void Oracle_OnAll()
{
   int nSym = ArraySize(g_oSym);
   for (int i = 0; i < nSym; i++)
   {
      if (Oracle_EngineA) Oracle_OnSymbol(i, MAGIC_ORACLE_A);
      if (Oracle_EngineB) Oracle_OnSymbol(i, MAGIC_ORACLE_B);
   }
}

//------------------------------------------------------------------
// Chart visuals for the chart's own symbol (prefix ORV_). Redrawn each
// timer tick: entry arrows, per-position TP lines, basket average line,
// next grid-level line, and a "why idle" status label. All cleared and
// rebuilt so nothing goes stale.
//------------------------------------------------------------------
void Oracle_ClearVisuals() { ObjectsDeleteAll(0, "ORV_"); }

void Oracle_HLine(string name, double price, color clr, int style, int width, string text)
{
   if (ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_HLINE, 0, 0, price);
   ObjectSetDouble(0, name, OBJPROP_PRICE, price);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_STYLE, style);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, width);
   ObjectSetInteger(0, name, OBJPROP_BACK, false);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
}

void Oracle_Arrow(string name, datetime t, double price, int dir, color clr)
{
   if (ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_ARROW, 0, t, price);
   ObjectSetInteger(0, name, OBJPROP_TIME, t);
   ObjectSetDouble(0, name, OBJPROP_PRICE, price);
   ObjectSetInteger(0, name, OBJPROP_ARROWCODE, dir > 0 ? 233 : 234); // up/down
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
}

void Oracle_StatusLabel(string text, color clr)
{
   string nm = "ORV_status";
   if (ObjectFind(0, nm) < 0)
   {
      ObjectCreate(0, nm, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, nm, OBJPROP_CORNER, CORNER_RIGHT_UPPER);
      ObjectSetInteger(0, nm, OBJPROP_XDISTANCE, 12);
      ObjectSetInteger(0, nm, OBJPROP_YDISTANCE, 22);
      ObjectSetInteger(0, nm, OBJPROP_ANCHOR, ANCHOR_RIGHT_UPPER);
      ObjectSetInteger(0, nm, OBJPROP_FONTSIZE, 10);
   }
   ObjectSetString(0, nm, OBJPROP_TEXT, text);
   ObjectSetInteger(0, nm, OBJPROP_COLOR, clr);
}

void Oracle_DrawChart()
{
   Oracle_ClearVisuals();
   string sym = _Symbol;
   int idx = Oracle_SymIndex(sym);
   if (idx < 0) return;   // this chart's symbol is not an Oracle symbol

   double pip = Oracle_Pip(sym);
   double bid = SymbolInfoDouble(sym, SYMBOL_BID);
   int    dg  = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);

   // --- per-position arrows + TP lines (both engines) ---
   int drawn = 0;
   int engines[2]; engines[0] = MAGIC_ORACLE_A; engines[1] = MAGIC_ORACLE_B;
   for (int e = 0; e < 2; e++)
   {
      int n, dir; double lots, avg, pl, last;
      Oracle_Basket(sym, engines[e], n, dir, lots, avg, pl, last);
      for (int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong tk = PositionGetTicket(i);
         if (!PositionSelectByTicket(tk)) continue;
         if (PositionGetString(POSITION_SYMBOL) != sym) continue;
         if ((int)PositionGetInteger(POSITION_MAGIC) != engines[e]) continue;
         double op = PositionGetDouble(POSITION_PRICE_OPEN);
         double tp = PositionGetDouble(POSITION_TP);
         bool isBuy = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
         datetime ot = (datetime)PositionGetInteger(POSITION_TIME);
         // entry arrow
         Oracle_Arrow(StringFormat("ORV_a_%I64u", tk), ot, op, isBuy ? 1 : -1,
                      isBuy ? clrDodgerBlue : clrOrangeRed);
         // TP line for this position (green = where it banks +TP)
         if (tp > 0)
            Oracle_HLine(StringFormat("ORV_tp_%I64u", tk), tp, clrLimeGreen,
                         STYLE_DOT, 1, StringFormat("TP e%d", e));
         drawn++;
      }
      // --- basket average + next grid level (per engine) ---
      if (n > 0)
      {
         int effCap = Oracle_EffectiveMaxLevels();
         Oracle_HLine(StringFormat("ORV_avg_%d", e), avg, clrGold, STYLE_SOLID, 1,
                      StringFormat("avg e%d (%d/%d)", e, n, effCap));
         // next grid add price: GridSize pips further against 'last'
         double nextPx = (dir < 0) ? last + EffGrid() * pip
                                   : last - EffGrid() * pip;
         bool capped = (n >= effCap);
         Oracle_HLine(StringFormat("ORV_next_%d", e),
                      NormalizeDouble(nextPx, dg),
                      capped ? clrGray : clrTomato, STYLE_DASH, 1,
                      capped ? StringFormat("grid CAP e%d", e)
                             : StringFormat("next add e%d", e));
      }
   }

   // --- status label: what the bot is doing / why idle ---
   int bias = Oracle_Bias(idx);
   double spr = Oracle_SpreadPoints(sym);
   bool spreadOK = (Oracle_MaxSpread <= 0) || (spr <= Oracle_MaxSpread);
   string st; color stc;
   if (!OracleOn())            { st = "ORACLE OFF"; stc = clrGray; }
   else if (!MarketOpen(sym))  { st = "MERCADO CERRADO (sesion broker)"; stc = clrOrangeRed; }
   else if (ServerBlocked(sym)){ st = "SERVIDOR BLOQUEA AT (backoff)"; stc = clrOrangeRed; }
   else if (HourBlocked())     { st = "HORA BLOQUEADA (" + RiskName(HourRisk(NowMinUTC())) + ")"; stc = clrOrange; }
   else if (SchedBlocked())    { st = "HORARIO BLOQUEADO (scheduler)"; stc = clrOrange; }
   else if (SymVolPaused(sym)) { st = "PAUSA VOLATILIDAD (regla C)"; stc = clrOrange; }
   else if (drawn > 0)         { st = StringFormat("OPERANDO (%d pos)", drawn); stc = clrLimeGreen; }
   else if (!spreadOK)         { st = StringFormat("ESPERA: spread %.0f > %d", spr, Oracle_MaxSpread); stc = clrGold; }
   else if (bias == 0)         { st = "ESPERA: sin senal (HiLo+EMA)"; stc = clrSilver; }
   else                        { st = StringFormat("LISTO: senal %s", bias > 0 ? "BUY" : "SELL"); stc = clrAqua; }
   Oracle_StatusLabel("ORACLE: " + st, stc);
}

//==================================================================
// Panel (CB_ prefix) + buttons
//==================================================================
#define PANEL_X     10
#define PANEL_Y     20
#define PANEL_W     480
// Capacity: ~27 fixed lines + 2 per traded symbol. Must cover the symbol list
// in the .chr — past this, SetLine writes to a CB_L<i> that does not exist and
// the text vanishes with no error (that is how the panel's tail went missing).
// It is only a ceiling: PanelUpdate parks the buttons under the LAST line it
// actually wrote, so spare capacity costs no blank space.
#define PANEL_LINES 40
#define LINE_H      16
// Characters that fit in PANEL_W at the panel font (~7.8 px/char). Derived, not
// guessed: PanelFit truncates to this, so a wider panel with a stale literal
// here would just show more empty space and keep cutting the text.
#define PANEL_CHARS ((PANEL_W - 20) / 8)

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

   // CLOSE ALL and RESET DAY are the buttons worth the screen space. PAUSE/
   // RESUME/ORACLE toggles are all reachable through ng_command.txt.
   // Three buttons share one row (a third each) so none falls off the bottom
   // of a short chart window. RESUME is here because a rule E pause is the one
   // state the panel cannot otherwise clear (RESETDAY only re-anchors the day).
   int by1   = PANEL_Y + PANEL_LINES * LINE_H + 5;
   int third = (PANEL_W - 14 - 8) / 3;   // three buttons, two 4px gaps
   PanelButton("CB_BTN_CLOSEALL", PANEL_X, by1, third, "CLOSE ALL", C'150,110,30');
   PanelButton("CB_BTN_RESETDAY", PANEL_X + third + 4, by1, third, "RESET DAY", C'30,110,110');
   PanelButton("CB_BTN_RESUME", PANEL_X + 2 * (third + 4), by1, third, "RESUME", C'30,110,50');
   PanelButtonsRefresh();
}

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

// The HYBRID/POWER buttons carried their own state in their label, so this
// refresh went with them. HYBRID/POWER state is still visible on the panel's
// header line and switchable through ng_command.txt.
void PanelButtonsRefresh()
{
   ObjectSetInteger(0, "CB_BTN_CLOSEALL", OBJPROP_STATE, false);
   ObjectSetInteger(0, "CB_BTN_RESETDAY", OBJPROP_STATE, false);
   ObjectSetInteger(0, "CB_BTN_RESUME", OBJPROP_STATE, false);
}

void SetLine(int i, string text, color clr = clrGainsboro)
{
   // Past PANEL_LINES there is no CB_L<i> object and the write vanishes with no
   // error: that is how the panel's tail went missing when the symbol list grew.
   // Say so instead of losing it.
   if (i >= PANEL_LINES)
   {
      static datetime lastWarn = 0;
      if (TimeGMT() - lastWarn > 300)
      {
         lastWarn = TimeGMT();
         Print(StringFormat("Cerberus PANEL: line %d exceeds PANEL_LINES (%d) - raise it: '%s'", i, PANEL_LINES, text));
      }
      return;
   }
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

void PanelUpdate()
{
   datetime nowG = TimeGMT();
   int line = 0;

   bool manual = GlobalVariableCheck(GV_MANUAL);
   string evName = "";
   bool inWin = InNewsWindow(evName);

   color cDim  = C'130,140,155';
   color cUp   = C'80,200,120';
   color cDown = C'230,90,90';
   color cWarn = C'240,180,60';

   // --- Guardian state
   if (manual)           SetLine(line++, "# CERBERUS: MANUAL PAUSE", clrOrange);
   else if (inWin)       SetLine(line++, PanelFit("# CERBERUS: NEWS PAUSE: " + evName), clrTomato);
   else if (GlobalVariableCheck(GV_SCHED))
                         SetLine(line++, "# CERBERUS: SCHEDULE PAUSE (AT OFF)", clrTomato);
   else if (InVolPause())
   {
      string paused = "";
      for (int vp = 0; vp < ArraySize(g_pairs); vp++)
         if (nowG < g_volPauseSym[vp])
            paused += (paused == "" ? "" : ",") + g_pairs[vp];
      SetLine(line++, PanelFit("# CERBERUS: VOLATILITY PAUSE only " + paused), clrTomato);
   }
   else                  SetLine(line++, "# CERBERUS: RUNNING", clrLightGreen);

   SetLine(line++, StringFormat("AutoTrading: %s   Feed: %s%s",
           AutoTradingOn() ? "ON" : "OFF", g_feedStatus,
           g_lastFeedOk > 0 ? " (" + FmtCountdown((int)(nowG - g_lastFeedOk)) + ")" : ""),
           AutoTradingOn() ? clrLightGreen : clrTomato);

   // --- Hour window (gold risk table, Colombia = UTC-5)
   {
      int hm = NowMinUTC();
      int hr = HourRisk(hm);
      int colMin = (hm + 1140) % 1440;   // Colombia time
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
   for (int i = 0; i < g_evCount; i++)
      if (g_evTime[i] > nowG && (nextIdx == -1 || g_evTime[i] < g_evTime[nextIdx]))
         nextIdx = i;
   if (nextIdx >= 0)
   {
      int toEvent = (int)(g_evTime[nextIdx] - nowG);
      int toPause = toEvent - MinutesBefore * 60;
      SetLine(line++, PanelFit("NEXT: " + g_evCountry[nextIdx] + " " + g_evTitle[nextIdx]), clrKhaki);
      SetLine(line++, StringFormat("  in %s (pause in %s)", FmtCountdown(toEvent), FmtCountdown(toPause)), clrKhaki);
   }
   else
   {
      SetLine(line++, "NEXT: (none on the calendar)", clrGray);
   }
   SetLine(line++, "---------------------------------------------------------");

   // --- ORACLE: header + 1-2 lines per symbol/engine basket
   {
      SetLine(line++, StringFormat("ORACLE EMA%d %s [%s] TP%.0f grid%.0f lot%.2f x%.1f  eng %s%s",
              Oracle_MaPeriod, EnumToString(Oracle_TF),
              OracleOn() ? "ON" : "OFF", EffTP(), EffGrid(), EffLot(), EffFactor(),
              Oracle_EngineA ? "A" : "-", Oracle_EngineB ? "B" : "-"),
              OracleOn() ? clrLightGreen : cDim);

      double exposure = 0;
      for (int s = 0; s < ArraySize(g_oSym); s++)
      {
         string sym = g_oSym[s];
         double pip = Oracle_Pip(sym);
         double sbid = SymbolInfoDouble(sym, SYMBOL_BID);
         int engines[2]; engines[0] = MAGIC_ORACLE_A; engines[1] = MAGIC_ORACLE_B;
         for (int e = 0; e < 2; e++)
         {
            int n, dir; double totLots, avg, pl, lastLevel;
            Oracle_Basket(sym, engines[e], n, dir, totLots, avg, pl, lastLevel);
            exposure += totLots;
            if (n == 0)
            {
               if (SymVolPaused(sym))
                  SetLine(line++, StringFormat("%-8s e%d VOL PAUSE (rule C)", sym, e), cWarn);
               else if (HourBlocked())
                  SetLine(line++, StringFormat("%-8s e%d HOUR BLOCK %s", sym, e, RiskName(HourRisk(NowMinUTC()))), cWarn);
               else
               {
                  int bias = Oracle_Bias(s);
                  SetLine(line++, StringFormat("%-8s e%d  no basket  bias %s", sym, e,
                          bias > 0 ? "BUY" : bias < 0 ? "SELL" : "-"),
                          bias > 0 ? cUp : bias < 0 ? cDown : cDim);
               }
            }
            else
            {
               double tpPx = (dir > 0) ? avg + EffTP() * pip : avg - EffTP() * pip;
               SetLine(line++, StringFormat("%-8s e%d %s grid %d  %.2f lots  $%+.2f", sym, e,
                       (dir > 0) ? "BUY " : "SELL", n, totLots, pl),
                       (pl >= 0) ? cUp : cWarn);
               SetLine(line++, StringFormat("  TP at %.0fp | avg %.3f",
                       (pip > 0) ? MathAbs(tpPx - sbid) / pip : 0, avg), cDim);
            }
         }
      }

      SetLine(line++, StringFormat("baskets closed %d | realized $%+.2f | exp %.2f lots",
              g_oCycles, g_oRealized, exposure), cDim);
   }
   SetLine(line++, "---------------------------------------------------------");

   // --- Last closed trades
   SetLine(line++, "LAST TRADES:", clrSilver);
   int shownH = 0, dayN = 0; double dayPL = 0;
   datetime day0 = iTime(_Symbol, PERIOD_D1, 0);
   HistorySelect(nowG - 7 * 86400, nowG + 3600);
   for (int h = HistoryDealsTotal() - 1; h >= 0; h--)
   {
      ulong dtk = HistoryDealGetTicket(h);
      if (dtk == 0) continue;
      long entry = HistoryDealGetInteger(dtk, DEAL_ENTRY);
      if (entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY) continue;
      long dtype = HistoryDealGetInteger(dtk, DEAL_TYPE);
      if (dtype != DEAL_TYPE_BUY && dtype != DEAL_TYPE_SELL) continue;
      datetime closeT = (datetime)HistoryDealGetInteger(dtk, DEAL_TIME);
      double hpl = HistoryDealGetDouble(dtk, DEAL_PROFIT) + HistoryDealGetDouble(dtk, DEAL_SWAP)
                 + HistoryDealGetDouble(dtk, DEAL_COMMISSION);
      if (closeT >= day0) { dayPL += hpl; dayN++; }
      if (shownH < 5)
      {
         // With the POSITION's symbol and side (the exit deal is opposite)
         string dsym = HistoryDealGetString(dtk, DEAL_SYMBOL);
         string side = (dtype == DEAL_TYPE_SELL) ? "BUY " : "SELL";
         SetLine(line++, StringFormat("  %s %-7s %s %.2f  $%+.2f",
                 TimeToString(closeT, TIME_MINUTES), StringSubstr(dsym, 0, 7), side,
                 HistoryDealGetDouble(dtk, DEAL_VOLUME), hpl),
                 hpl >= 0 ? clrLightGreen : clrTomato);
         shownH++;
      }
      else if (closeT < day0) break;
   }
   if (shownH == 0) SetLine(line++, "  (no closed trades)", clrGray);
   SetLine(line++, "---------------------------------------------------------");
   // Day P/L MEASURED LIKE RULE E: equity vs baseline (RESETDAY re-anchors).
   // The day's history is shown as a trade count.
   double dayBase = GlobalVariableCheck("NG_DayStartBal") ? GlobalVariableGet("NG_DayStartBal") : AccountInfoDouble(ACCOUNT_BALANCE);
   double dayEq = AccountInfoDouble(ACCOUNT_EQUITY) - dayBase;
   SetLine(line++, StringFormat("DAY P/L (since reset): $%+.2f  |  %d trades today", dayEq, dayN),
           dayEq >= 0 ? clrLightGreen : clrTomato);
   SetLine(line++, StringFormat("Brakes (guardian): day -%.0f | pos -%.0f | rule C closes",
           MaxDailyLossUSD, MaxLossPerTradeUSD), cDim);

   // --- Account
   double ml = MarginLevelPct();
   color mlClr = clrLightGreen;
   if (MinMarginLevelPct > 0 && ml < MinMarginLevelPct * 1.25) mlClr = clrTomato;
   SetLine(line++, StringFormat("Equity: %.2f  Free: %.2f  Margin: %s",
           AccountInfoDouble(ACCOUNT_EQUITY), AccountInfoDouble(ACCOUNT_MARGIN_FREE),
           ml >= 999999 ? "-" : StringFormat("%.0f%%", ml)), mlClr);

   // --- Last action
   SetLine(line++, PanelFit("Last action: " + g_lastAction), clrSilver);

   // Fit the frame and the buttons to the lines actually written: PANEL_LINES
   // is capacity, not usage, and anchoring to it left a dead gap above the
   // buttons whenever the symbol list was shorter than the ceiling.
   PanelFitTo(line);
   ChartRedraw();
}

// Park the background and both buttons right under line `used`. CLOSE ALL and
// RESET DAY and RESUME share one row (a third each) so all stay inside the grey panel.
void PanelFitTo(int used)
{
   int by1  = PANEL_Y + used * LINE_H + 6;
   int third = (PANEL_W - 14 - 8) / 3;   // three buttons, two 4px gaps
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

void PanelDelete()
{
   ObjectDelete(0, "CB_BG");
   for (int i = 0; i < PANEL_LINES; i++)
      ObjectDelete(0, "CB_L" + IntegerToString(i));
   // PAUSE/RESUME/HYBRID/POWER are gone from the panel; still deleted here so
   // an upgrade from a build that drew them does not leave them orphaned.
   ObjectDelete(0, "CB_BTN_PAUSE");
   ObjectDelete(0, "CB_BTN_RESUME");
   ObjectDelete(0, "CB_BTN_CLOSEALL");
   ObjectDelete(0, "CB_BTN_RESETDAY");
   ObjectDelete(0, "CB_BTN_HYBRID");
   ObjectDelete(0, "CB_BTN_POWER");
}

//==================================================================
// Buttons
//==================================================================
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   if (id != CHARTEVENT_OBJECT_CLICK) return;

   if (sparam == "CB_BTN_PAUSE")
   {
      LogAction("MANUAL_PAUSE", "PAUSE NOW button");
      CloseAllOrders("manual pause");
      SetAutoTrading(false);
      GlobalVariableSet(GV_MANUAL, 1);
      g_lastAction = "Manual pause on";
   }
   else if (sparam == "CB_BTN_RESUME")
   {
      LogAction("MANUAL_RESUME", "RESUME button");
      GlobalVariableDel(GV_MANUAL);
      GlobalVariableDel(GV_GUARD);
      SetAutoTrading(true);
      g_lastAction = "Resumed manually";
   }
   else if (sparam == "CB_BTN_CLOSEALL")
   {
      LogAction("MANUAL_CLOSEALL", "CLOSE ALL button");
      CloseAllOrders("manual close");
   }
   else if (sparam == "CB_BTN_RESETDAY")
      DoResetDay();
   else if (sparam == "CB_BTN_ORACLE")
      Oracle_SetOn(!OracleOn());
   else return;

   ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
   PanelUpdate();
}
