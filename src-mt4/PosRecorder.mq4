//+------------------------------------------------------------------+
//| PosRecorder MT4 - read-only 1 Hz snapshot of every open order.    |
//| MT4 twin of src-mt5\PosRecorder.mq5: same columns, same delimiter |
//| and the same flat-account heartbeat, so both captures drop into   |
//| one comparison without any per-platform special-casing.           |
//|                                                                   |
//| Read-only by design: it never opens, modifies or closes anything. |
//| Here it watches Oracle 2.0 (magics 7799 / 9977), which is a third |
//| party binary - this file is the ONLY telemetry we can get out of  |
//| it, so it records every order in the account, magic included, and |
//| lets the analysis filter later.                                   |
//|                                                                   |
//| age_s (not the raw open time) is the field to compare ACROSS      |
//| platforms: the two brokers' server clocks differ, ages do not.    |
//+------------------------------------------------------------------+
#property copyright "Harrinson Gutierrez"
#property strict
#property version   "1.0"

input string OutFile       = "pos_snapshot_mt4.csv";   // CSV in MQL4\Files
input int    SampleSeconds = 1;                        // sampling period
input string FilterSymbol  = "";                       // "" = every symbol

string HEADER = "ts_gmt;equity;balance;floating;n_pos;ticket;magic;symbol;type;lots;open_price;age_s;sl;tp;profit;swap;bid;ask;spread_pts";

int OnInit()
{
   if (!FileIsExist(OutFile))
   {
      int hn = FileOpen(OutFile, FILE_READ|FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_SHARE_READ|FILE_SHARE_WRITE);
      if (hn != INVALID_HANDLE) { FileWriteString(hn, HEADER + "\r\n"); FileClose(hn); }
   }
   EventSetTimer(SampleSeconds < 1 ? 1 : SampleSeconds);
   Sample();
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason) { EventKillTimer(); }
void OnTimer() { Sample(); }

bool InScope(int idx)
{
   if (!OrderSelect(idx, SELECT_BY_POS, MODE_TRADES)) return(false);
   if (OrderType() != OP_BUY && OrderType() != OP_SELL) return(false);   // market positions only
   if (FilterSymbol != "" && OrderSymbol() != FilterSymbol) return(false);
   return(true);
}

void Sample()
{
   string ts  = TimeToString(TimeGMT(), TIME_DATE|TIME_SECONDS);
   double eq  = AccountEquity();
   double bal = AccountBalance();

   int    n = 0;
   double floating = 0;
   for (int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if (!InScope(i)) continue;
      floating += OrderProfit() + OrderSwap() + OrderCommission();
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

   for (int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if (!InScope(i)) continue;
      string sym = OrderSymbol();
      int    dg  = (int)MarketInfo(sym, MODE_DIGITS);
      double pt  = MarketInfo(sym, MODE_POINT);
      double bid = MarketInfo(sym, MODE_BID);
      double ask = MarketInfo(sym, MODE_ASK);

      FileWriteString(h, StringFormat("%s;%d;%d;%s;%s;%.2f;%s;%d;%s;%s;%.2f;%.2f;%s;%s;%.0f\r\n",
         head,
         OrderTicket(),
         OrderMagicNumber(),
         sym,
         (OrderType() == OP_BUY) ? "BUY" : "SELL",
         OrderLots(),
         DoubleToString(OrderOpenPrice(), dg),
         (int)(TimeCurrent() - OrderOpenTime()),
         DoubleToString(OrderStopLoss(), dg),
         DoubleToString(OrderTakeProfit(), dg),
         OrderProfit() + OrderCommission(),
         OrderSwap(),
         DoubleToString(bid, dg),
         DoubleToString(ask, dg),
         (pt > 0) ? (ask - bid) / pt : 0.0));
   }
   FileClose(h);
}
