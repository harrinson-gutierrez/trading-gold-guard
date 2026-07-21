//+------------------------------------------------------------------+
//| PosRecorder MT5 - read-only 1 Hz snapshot of every open position. |
//| Writes MQL5\Files\<OutFile> as CSV (';'), ONE LINE PER POSITION   |
//| per sample, plus a heartbeat line when the account is flat - so   |
//| the analysis can tell "no positions" apart from "no data".        |
//|                                                                   |
//| Read-only by design: it never opens, modifies or closes anything. |
//| It exists to compare the Cerberus engine (MT5) against Oracle 2.0 |
//| (MT4) second by second: same entries? same side? what pip step    |
//| between grid levels, what depth per engine (magic), how long does |
//| a cycle live, at what distance is the basket TP taken.            |
//|                                                                   |
//| age_s (not the raw open time) is the field to compare ACROSS      |
//| platforms: the two brokers' server clocks differ, ages do not.    |
//+------------------------------------------------------------------+
#property copyright "Harrinson Gutierrez"
#property version   "1.0"

input string OutFile       = "pos_snapshot_mt5.csv";   // CSV in MQL5\Files
input int    SampleSeconds = 1;                        // sampling period
input string FilterSymbol  = "";                       // "" = every symbol

const string HEADER = "ts_gmt;equity;balance;floating;n_pos;ticket;magic;symbol;type;lots;open_price;age_s;sl;tp;profit;swap;bid;ask;spread_pts";

int OnInit()
{
   if (!FileIsExist(OutFile))
   {
      int h = FileOpen(OutFile, FILE_READ|FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_SHARE_READ|FILE_SHARE_WRITE);
      if (h != INVALID_HANDLE) { FileWriteString(h, HEADER + "\r\n"); FileClose(h); }
   }
   EventSetTimer(SampleSeconds < 1 ? 1 : SampleSeconds);
   Sample();
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) { EventKillTimer(); }
void OnTimer() { Sample(); }

void Sample()
{
   string ts   = TimeToString(TimeGMT(), TIME_DATE|TIME_SECONDS);
   double eq   = AccountInfoDouble(ACCOUNT_EQUITY);
   double bal  = AccountInfoDouble(ACCOUNT_BALANCE);

   // First pass: count the positions in scope and add up their floating P/L.
   int    n = 0;
   double floating = 0;
   for (int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if (!PositionSelectByTicket(tk)) continue;
      if (FilterSymbol != "" && PositionGetString(POSITION_SYMBOL) != FilterSymbol) continue;
      floating += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      n++;
   }

   int h = FileOpen(OutFile, FILE_READ|FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_SHARE_READ|FILE_SHARE_WRITE);
   if (h == INVALID_HANDLE) return;
   FileSeek(h, 0, SEEK_END);

   string head = StringFormat("%s;%.2f;%.2f;%.2f;%d", ts, eq, bal, floating, n);

   if (n == 0)
   {
      // Heartbeat: the account IS flat at this second (not a gap in the capture).
      FileWriteString(h, head + ";0;0;;;0;0;0;0;0;0;0;0;0;0\r\n");
      FileClose(h);
      return;
    }

   for (int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if (!PositionSelectByTicket(tk)) continue;
      string sym = PositionGetString(POSITION_SYMBOL);
      if (FilterSymbol != "" && sym != FilterSymbol) continue;

      int    dg  = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
      double pt  = SymbolInfoDouble(sym, SYMBOL_POINT);
      double bid = SymbolInfoDouble(sym, SYMBOL_BID);
      double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
      long   age = (long)TimeCurrent() - (long)PositionGetInteger(POSITION_TIME);

      FileWriteString(h, StringFormat("%s;%I64u;%d;%s;%s;%.2f;%s;%I64d;%s;%s;%.2f;%.2f;%s;%s;%.0f\r\n",
         head,
         tk,
         (int)PositionGetInteger(POSITION_MAGIC),
         sym,
         (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? "BUY" : "SELL",
         PositionGetDouble(POSITION_VOLUME),
         DoubleToString(PositionGetDouble(POSITION_PRICE_OPEN), dg),
         age,
         DoubleToString(PositionGetDouble(POSITION_SL), dg),
         DoubleToString(PositionGetDouble(POSITION_TP), dg),
         PositionGetDouble(POSITION_PROFIT),
         PositionGetDouble(POSITION_SWAP),
         DoubleToString(bid, dg),
         DoubleToString(ask, dg),
         (pt > 0) ? (ask - bid) / pt : 0.0));
   }
   FileClose(h);
}
