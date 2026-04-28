//+------------------------------------------------------------------+
//|                  XAUUSD_Scalper_M1_v10.mq5                      |
//|  Strict M1 scalper for XAUUSD: M1 indicators + tick management   |
//+------------------------------------------------------------------+
#property copyright "2026 AndroindDeve + AI"
#property version   "10.01"
#property strict

#include <Trade\Trade.mqh>
CTrade trade;

//=== Inputs ==========================================================

input group "Profit and protection"
input double  ProfitTarget          = 1.5;    // Per-position profit target in account currency
input double  MaxLossPct            = 2.0;    // Max loss per position, % of balance
input double  AvgDrawdownPct        = 0.5;    // Position drawdown, % of balance, to average
input bool    UseAveraging          = false;  // Averaging is high risk; keep disabled unless tested
input int     MaxAvgLevels          = 3;
input double  AvgLotMult            = 1.5;

input group "Trailing stop"
input bool    UseTrailing           = true;
input double  TrailStart_Pips       = 10.0;
input double  TrailStep_Pips        = 5.0;

input group "Stop loss"
input bool    UseATR_SL             = true;
input int     ATR_Period            = 14;
input double  ATR_SL_Mult           = 1.5;
input double  FixedSL_Pips          = 30.0;

input group "Lots"
input double  BaseLot               = 0.01;
input double  MaxLotPerSignal       = 0.10;

input group "Signal sizing"
input int     WeakSignal_Pos        = 1;      // 1-4 points
input int     MedSignal_Pos         = 2;      // 5-7 points
input int     StrongSignal_Pos      = 3;      // 8+ points

input group "Execution filters"
input double  SpreadAtrReduce_1     = 0.35;   // Spread/ATR above this reduces position count by 1
input double  SpreadAtrReduce_2     = 0.70;   // Spread/ATR above this reduces position count by 2
input int     MaxTotalPositions     = 12;
input int     MaxPositionsPerSide   = 6;
input int     MinSecondsBetweenEntries = 20;
input bool    OneEntryPerM1Bar      = true;
input int     GMT_Offset            = 3;
input int     Session_Start_H       = 7;
input int     Session_End_H         = 21;

input group "M1 indicators only"
input int     EMA_Period            = 20;
input int     EMA_Slope_Bars        = 3;
input double  MinEmaDistance_Pips   = 0.8;    // Avoid entries directly on EMA
input int     ADX_Period            = 14;
input double  ADX_Min               = 18.0;
input int     RSI_Period            = 14;
input int     Stoch_K               = 5;
input int     Stoch_D               = 3;
input int     Stoch_Slowing         = 3;
input int     BB_Period             = 20;
input double  BB_Dev                = 2.0;
input int     MicroRange_Bars       = 5;      // Recent M1 candles used for micro momentum
input double  MinMicroRange_Pips    = 3.0;    // Skip dead tape

input group "Debug"
input bool    DebugMode             = true;

//=== Indicator handles ==============================================
int h_ema20_m1 = INVALID_HANDLE;
int h_adx_m1   = INVALID_HANDLE;
int h_rsi_m1   = INVALID_HANDLE;
int h_macd_m1  = INVALID_HANDLE;
int h_stoch_m1 = INVALID_HANDLE;
int h_atr_m1   = INVALID_HANDLE;
int h_bb_m1    = INVALID_HANDLE;

//=== Globals =========================================================
long     MAGIC              = 20261000;
double   PipSize            = 0.0;
datetime last_m1_bar_time   = 0;
datetime last_entry_time    = 0;
datetime last_entry_bar     = 0;
int      last_direction     = 0;
int      avg_levels_buy     = 0;
int      avg_levels_sell    = 0;

struct SignalData
{
   int    direction;
   int    score;
   int    positions;
   double sl_price;
   string reason;
};

//+------------------------------------------------------------------+
int OnInit()
{
   PipSize = CalcPipSize();

   h_ema20_m1 = iMA(_Symbol, PERIOD_M1, EMA_Period, 0, MODE_EMA, PRICE_CLOSE);
   h_adx_m1   = iADX(_Symbol, PERIOD_M1, ADX_Period);
   h_rsi_m1   = iRSI(_Symbol, PERIOD_M1, RSI_Period, PRICE_CLOSE);
   h_macd_m1  = iMACD(_Symbol, PERIOD_M1, 12, 26, 9, PRICE_CLOSE);
   h_stoch_m1 = iStochastic(_Symbol, PERIOD_M1, Stoch_K, Stoch_D, Stoch_Slowing,
                            MODE_SMA, STO_LOWHIGH);
   h_atr_m1   = iATR(_Symbol, PERIOD_M1, ATR_Period);
   h_bb_m1    = iBands(_Symbol, PERIOD_M1, BB_Period, 0, BB_Dev, PRICE_CLOSE);

   if(h_ema20_m1 == INVALID_HANDLE || h_adx_m1   == INVALID_HANDLE ||
      h_rsi_m1   == INVALID_HANDLE || h_macd_m1  == INVALID_HANDLE ||
      h_stoch_m1 == INVALID_HANDLE || h_atr_m1   == INVALID_HANDLE ||
      h_bb_m1    == INVALID_HANDLE)
   {
      Print("Indicator init failed. All indicators must be PERIOD_M1.");
      return INIT_FAILED;
   }

   trade.SetExpertMagicNumber(MAGIC);
   trade.SetDeviationInPoints(30);
   trade.SetAsyncMode(false);

   Print("XAUUSD Scalper M1 v10.01 started. Spread never blocks entries; PERIOD_M1 indicators, tick management enabled.");
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(h_ema20_m1);
   IndicatorRelease(h_adx_m1);
   IndicatorRelease(h_rsi_m1);
   IndicatorRelease(h_macd_m1);
   IndicatorRelease(h_stoch_m1);
   IndicatorRelease(h_atr_m1);
   IndicatorRelease(h_bb_m1);
}

//+------------------------------------------------------------------+
void OnTick()
{
   ManagePositions();
   ApplyTrailing();
   if(UseAveraging)
      CheckAveraging();

   if(!IsTradingSession())
      return;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0 || bid <= 0 || ask <= bid)
      return;

   if(CountOurPositions() >= MaxTotalPositions)
      return;

   if(!CanOpenNewEntry())
      return;

   SignalData sig = ReadAndAnalyzeSignal(ask, bid);

   if(DebugMode && IsNewM1Bar())
   {
      Print("M1 signal: ", DirStr(sig.direction),
            " score=", sig.score,
            " positions=", sig.positions,
            " SL=", DoubleToString(sig.sl_price, _Digits),
            " | ", sig.reason);
   }

   if(sig.direction != 0)
      ExecuteSignal(sig, ask, bid);
}

//+------------------------------------------------------------------+
SignalData ReadAndAnalyzeSignal(double ask, double bid)
{
   SignalData empty;
   empty.direction = 0;
   empty.score     = 0;
   empty.positions = 0;
   empty.sl_price  = 0.0;
   empty.reason    = "";

   int ema_count = EMA_Slope_Bars + 2;
   double ema20[];
   double adx_main[], adx_plus[], adx_minus[];
   double rsi[], macd_m[], macd_s[];
   double stoch_k[], stoch_d[];
   double bb_up[], bb_mid[], bb_lo[];
   double atr[];

   if(!SafeCopy(h_ema20_m1, 0, ema20,     ema_count)) return empty;
   if(!SafeCopy(h_adx_m1,   0, adx_main,  4))         return empty;
   if(!SafeCopy(h_adx_m1,   1, adx_plus,  4))         return empty;
   if(!SafeCopy(h_adx_m1,   2, adx_minus, 4))         return empty;
   if(!SafeCopy(h_rsi_m1,   0, rsi,       4))         return empty;
   if(!SafeCopy(h_macd_m1,  0, macd_m,    4))         return empty;
   if(!SafeCopy(h_macd_m1,  1, macd_s,    4))         return empty;
   if(!SafeCopy(h_stoch_m1, 0, stoch_k,   4))         return empty;
   if(!SafeCopy(h_stoch_m1, 1, stoch_d,   4))         return empty;
   if(!SafeCopy(h_bb_m1,    0, bb_up,     4))         return empty;
   if(!SafeCopy(h_bb_m1,    1, bb_mid,    4))         return empty;
   if(!SafeCopy(h_bb_m1,    2, bb_lo,     4))         return empty;
   if(!SafeCopy(h_atr_m1,   0, atr,       4))         return empty;

   return AnalyzeSignal(ema20, adx_main, adx_plus, adx_minus,
                        rsi, macd_m, macd_s, stoch_k, stoch_d,
                        bb_up, bb_mid, bb_lo, atr, ask, bid);
}

//+------------------------------------------------------------------+
SignalData AnalyzeSignal(double &ema20[],
                         double &adx_main[], double &adx_plus[], double &adx_minus[],
                         double &rsi[],
                         double &macd_m[], double &macd_s[],
                         double &stoch_k[], double &stoch_d[],
                         double &bb_up[], double &bb_mid[], double &bb_lo[],
                         double &atr[],
                         double ask, double bid)
{
   SignalData sig;
   sig.direction = 0;
   sig.score     = 0;
   sig.positions = 0;
   sig.sl_price  = 0.0;
   sig.reason    = "";

   double price_now = (ask + bid) / 2.0;
   double ema_now   = ema20[0];
   double dist_pips = (price_now - ema_now) / PipSize;

   if(adx_main[1] < ADX_Min)
   {
      sig.reason = "flat ADX=" + DoubleToString(adx_main[1], 1);
      return sig;
   }

   int direction = 0;
   if(dist_pips >= MinEmaDistance_Pips)
      direction = 1;
   else if(dist_pips <= -MinEmaDistance_Pips)
      direction = -1;
   else
   {
      sig.reason = "too close to EMA20 M1";
      return sig;
   }

   int same_side_positions = CountOurPositionsByType(direction);
   if(same_side_positions >= MaxPositionsPerSide)
   {
      sig.reason = "max positions per side";
      return sig;
   }

   int score = 0;
   sig.reason = (direction == 1)
                ? "EMA20_M1_BUY "
                : "EMA20_M1_SELL ";

   double slope = (ema20[0] - ema20[EMA_Slope_Bars]) / PipSize;
   if(direction == 1)
   {
      if(slope > 2.0)       { score += 3; sig.reason += "EMA_slope_strong_up "; }
      else if(slope > 0.5)  { score += 2; sig.reason += "EMA_slope_up "; }
      else if(slope >= 0.0) { score += 1; sig.reason += "EMA_flat_up "; }
      else                  { score -= 2; sig.reason += "EMA_slope_against "; }
   }
   else
   {
      if(slope < -2.0)      { score += 3; sig.reason += "EMA_slope_strong_down "; }
      else if(slope < -0.5) { score += 2; sig.reason += "EMA_slope_down "; }
      else if(slope <= 0.0) { score += 1; sig.reason += "EMA_flat_down "; }
      else                  { score -= 2; sig.reason += "EMA_slope_against "; }
   }

   bool di_bull = (adx_plus[1] > adx_minus[1]);
   bool di_bear = (adx_minus[1] > adx_plus[1]);
   if(direction == 1 && di_bull)  { score += (adx_main[1] > 30.0 ? 2 : 1); sig.reason += "ADX_DI_buy "; }
   if(direction == -1 && di_bear) { score += (adx_main[1] > 30.0 ? 2 : 1); sig.reason += "ADX_DI_sell "; }
   if(direction == 1 && !di_bull)  { score -= 1; sig.reason += "DI_against "; }
   if(direction == -1 && !di_bear) { score -= 1; sig.reason += "DI_against "; }

   double macd_hist_1 = macd_m[1] - macd_s[1];
   double macd_hist_2 = macd_m[2] - macd_s[2];
   if(direction == 1)
   {
      if(macd_hist_1 > 0.0 && macd_hist_1 > macd_hist_2) { score += 2; sig.reason += "MACD_up_strong "; }
      else if(macd_hist_1 > 0.0)                         { score += 1; sig.reason += "MACD_up "; }
      else                                               { score -= 1; sig.reason += "MACD_against "; }
   }
   else
   {
      if(macd_hist_1 < 0.0 && macd_hist_1 < macd_hist_2) { score += 2; sig.reason += "MACD_down_strong "; }
      else if(macd_hist_1 < 0.0)                         { score += 1; sig.reason += "MACD_down "; }
      else                                               { score -= 1; sig.reason += "MACD_against "; }
   }

   if(direction == 1)
   {
      if(rsi[1] > 55.0 && rsi[1] < 70.0)       { score += 3; sig.reason += "RSI_buy_power "; }
      else if(rsi[1] >= 50.0 && rsi[1] <= 55.0){ score += 2; sig.reason += "RSI_buy_ok "; }
      else if(rsi[1] >= 40.0 && rsi[1] < 50.0) { score += 1; sig.reason += "RSI_buy_weak "; }
      else if(rsi[1] >= 70.0)                  { score -= 2; sig.reason += "RSI_overbought "; }
   }
   else
   {
      if(rsi[1] < 45.0 && rsi[1] > 30.0)       { score += 3; sig.reason += "RSI_sell_power "; }
      else if(rsi[1] >= 45.0 && rsi[1] <= 50.0){ score += 2; sig.reason += "RSI_sell_ok "; }
      else if(rsi[1] > 50.0 && rsi[1] <= 60.0) { score += 1; sig.reason += "RSI_sell_weak "; }
      else if(rsi[1] <= 30.0)                  { score -= 2; sig.reason += "RSI_oversold "; }
   }

   if(direction == 1)
   {
      if(stoch_k[1] < 80.0 && stoch_k[1] > stoch_d[1]) { score += 2; sig.reason += "Stoch_up "; }
      else if(stoch_k[1] < 80.0)                       { score += 1; sig.reason += "Stoch_buy_ok "; }
      else                                             { score -= 1; sig.reason += "Stoch_overbought "; }
   }
   else
   {
      if(stoch_k[1] > 20.0 && stoch_k[1] < stoch_d[1]) { score += 2; sig.reason += "Stoch_down "; }
      else if(stoch_k[1] > 20.0)                       { score += 1; sig.reason += "Stoch_sell_ok "; }
      else                                             { score -= 1; sig.reason += "Stoch_oversold "; }
   }

   double close_m1 = iClose(_Symbol, PERIOD_M1, 1);
   if(direction == 1 && close_m1 > bb_mid[1] && close_m1 < bb_up[1])
      { score += 1; sig.reason += "BB_buy_zone "; }
   else if(direction == -1 && close_m1 < bb_mid[1] && close_m1 > bb_lo[1])
      { score += 1; sig.reason += "BB_sell_zone "; }

   double micro_range = RecentRangePips(MicroRange_Bars);
   if(micro_range < MinMicroRange_Pips)
   {
      sig.reason += "dead_micro_range=" + DoubleToString(micro_range, 1);
      return sig;
   }

   double micro_momentum = (iClose(_Symbol, PERIOD_M1, 1) -
                            iOpen(_Symbol, PERIOD_M1, MathMax(1, MicroRange_Bars))) / PipSize;
   if(direction == 1 && micro_momentum > 0.0)
      { score += 1; sig.reason += "micro_up "; }
   else if(direction == -1 && micro_momentum < 0.0)
      { score += 1; sig.reason += "micro_down "; }
   else
      { score -= 1; sig.reason += "micro_against "; }

   if(score < 4)
   {
      sig.reason += "score_too_low=" + IntegerToString(score);
      return sig;
   }

   score = MathMin(score, 12);

   int positions = WeakSignal_Pos;
   if(score >= 8)
      positions = StrongSignal_Pos;
   else if(score >= 5)
      positions = MedSignal_Pos;

   int by_lot_cap = (int)MathFloor(MaxLotPerSignal / BaseLot);
   positions = MathMax(1, MathMin(positions, by_lot_cap));
   positions = MathMin(positions, MaxPositionsPerSide - same_side_positions);

   double spread_pips = (ask - bid) / PipSize;
   double spread_atr_ratio = (atr[1] > 0.0) ? ((ask - bid) / atr[1]) : 0.0;
   int spread_reduction = 0;
   if(spread_atr_ratio >= SpreadAtrReduce_2)
      spread_reduction = 2;
   else if(spread_atr_ratio >= SpreadAtrReduce_1)
      spread_reduction = 1;

   if(spread_reduction > 0)
      positions = MathMax(1, positions - spread_reduction);

   sig.reason += "spread=" + DoubleToString(spread_pips, 1) +
                 "p ATRratio=" + DoubleToString(spread_atr_ratio, 2) + " ";

   if(positions <= 0)
   {
      sig.reason += "no side capacity";
      return sig;
   }

   sig.direction = direction;
   sig.score     = score;
   sig.positions = positions;
   sig.sl_price  = CalcSL(direction, atr[1], ask, bid);
   return sig;
}

//+------------------------------------------------------------------+
double CalcSL(int direction, double atr_val, double ask, double bid)
{
   double sl_dist = FixedSL_Pips * PipSize;
   if(UseATR_SL && atr_val > 0.0)
      sl_dist = MathMax(atr_val * ATR_SL_Mult, FixedSL_Pips * PipSize * 0.5);

   double sl = (direction == 1) ? bid - sl_dist : ask + sl_dist;
   sl = NormalizeStopForBroker(direction, sl, ask, bid);
   return NormalizeDouble(sl, _Digits);
}

//+------------------------------------------------------------------+
double NormalizeStopForBroker(int direction, double sl, double ask, double bid)
{
   int stops_level = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   if(stops_level <= 0)
      return sl;

   double min_dist = stops_level * _Point;
   if(direction == 1)
      return MathMin(sl, bid - min_dist);

   return MathMax(sl, ask + min_dist);
}

//+------------------------------------------------------------------+
void ExecuteSignal(SignalData &sig, double ask, double bid)
{
   int opened = 0;
   double lot = NormLot(BaseLot);

   for(int i = 0; i < sig.positions; i++)
   {
      bool ok = false;
      ResetLastError();

      if(sig.direction == 1)
         ok = trade.Buy(lot, _Symbol, ask, sig.sl_price, 0.0, "M1 scalp buy");
      else
         ok = trade.Sell(lot, _Symbol, bid, sig.sl_price, 0.0, "M1 scalp sell");

      if(ok)
      {
         opened++;
      }
      else
      {
         Print("Order failed retcode=", trade.ResultRetcode(),
               " desc=", trade.ResultRetcodeDescription(),
               " last_error=", GetLastError());
         break;
      }
   }

   if(opened > 0)
   {
      last_direction  = sig.direction;
      last_entry_time = TimeCurrent();
      last_entry_bar  = iTime(_Symbol, PERIOD_M1, 0);
      if(sig.direction == 1)
         avg_levels_buy = 0;
      else
         avg_levels_sell = 0;

      Print("Opened ", opened, " ", DirStr(sig.direction),
            " score=", sig.score,
            " SL=", DoubleToString(sig.sl_price, _Digits),
            " | ", sig.reason);
   }
}

//+------------------------------------------------------------------+
void ManagePositions()
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double max_loss = balance * MaxLossPct / 100.0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!IsOurPosition(ticket))
         continue;

      double profit = PositionGetDouble(POSITION_PROFIT);

      if(profit >= ProfitTarget)
      {
         if(trade.PositionClose(ticket))
            Print("Profit close +", DoubleToString(profit, 2), " ticket=", ticket);
         continue;
      }

      if(profit < 0.0 && MathAbs(profit) >= max_loss)
      {
         if(trade.PositionClose(ticket))
            Print("Loss protection close ", DoubleToString(profit, 2), " ticket=", ticket);
      }
   }
}

//+------------------------------------------------------------------+
void ApplyTrailing()
{
   if(!UseTrailing)
      return;

   double trail_start = TrailStart_Pips * PipSize;
   double trail_step  = TrailStep_Pips  * PipSize;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!IsOurPosition(ticket))
         continue;

      long   ptype  = PositionGetInteger(POSITION_TYPE);
      double sl_cur = PositionGetDouble(POSITION_SL);
      double open_p = PositionGetDouble(POSITION_PRICE_OPEN);
      double tp_cur = PositionGetDouble(POSITION_TP);
      double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      if(ptype == POSITION_TYPE_BUY)
      {
         double new_sl = NormalizeDouble(bid - trail_step, _Digits);
         if(bid - open_p >= trail_start && (sl_cur == 0.0 || new_sl > sl_cur + _Point))
         {
            if(!trade.PositionModify(ticket, new_sl, tp_cur))
               Print("Trailing BUY failed retcode=", trade.ResultRetcodeDescription());
         }
      }
      else if(ptype == POSITION_TYPE_SELL)
      {
         double new_sl = NormalizeDouble(ask + trail_step, _Digits);
         if(open_p - ask >= trail_start && (sl_cur == 0.0 || new_sl < sl_cur - _Point))
         {
            if(!trade.PositionModify(ticket, new_sl, tp_cur))
               Print("Trailing SELL failed retcode=", trade.ResultRetcodeDescription());
         }
      }
   }
}

//+------------------------------------------------------------------+
void CheckAveraging()
{
   double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
   double threshold = balance * AvgDrawdownPct / 100.0;
   bool did_buy = false;
   bool did_sell = false;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!IsOurPosition(ticket))
         continue;

      double profit = PositionGetDouble(POSITION_PROFIT);
      long   ptype  = PositionGetInteger(POSITION_TYPE);
      if(profit >= 0.0 || MathAbs(profit) < threshold)
         continue;

      if(ptype == POSITION_TYPE_BUY && !did_buy && avg_levels_buy < MaxAvgLevels)
      {
         double lot = NormLot(BaseLot * MathPow(AvgLotMult, avg_levels_buy + 1));
         double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         if(trade.Buy(lot, _Symbol, ask, 0.0, 0.0, "M1 average buy"))
         {
            avg_levels_buy++;
            did_buy = true;
            Print("Average BUY level=", avg_levels_buy, " lot=", DoubleToString(lot, 2));
         }
      }

      if(ptype == POSITION_TYPE_SELL && !did_sell && avg_levels_sell < MaxAvgLevels)
      {
         double lot = NormLot(BaseLot * MathPow(AvgLotMult, avg_levels_sell + 1));
         double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         if(trade.Sell(lot, _Symbol, bid, 0.0, 0.0, "M1 average sell"))
         {
            avg_levels_sell++;
            did_sell = true;
            Print("Average SELL level=", avg_levels_sell, " lot=", DoubleToString(lot, 2));
         }
      }
   }
}

//+------------------------------------------------------------------+
bool CanOpenNewEntry()
{
   if(TimeCurrent() - last_entry_time < MinSecondsBetweenEntries)
      return false;

   if(OneEntryPerM1Bar)
   {
      datetime bar_time = iTime(_Symbol, PERIOD_M1, 0);
      if(bar_time == last_entry_bar)
         return false;
   }

   return true;
}

//+------------------------------------------------------------------+
bool IsNewM1Bar()
{
   datetime cur = iTime(_Symbol, PERIOD_M1, 0);
   if(cur != last_m1_bar_time)
   {
      last_m1_bar_time = cur;
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
bool IsTradingSession()
{
   datetime gmt = TimeCurrent() - GMT_Offset * 3600;
   MqlDateTime tm;
   TimeToStruct(gmt, tm);
   return (tm.hour >= Session_Start_H && tm.hour < Session_End_H);
}

//+------------------------------------------------------------------+
bool SafeCopy(int handle, int buffer, double &arr[], int count)
{
   if(handle == INVALID_HANDLE)
      return false;

   ArraySetAsSeries(arr, true);
   int copied = CopyBuffer(handle, buffer, 0, count, arr);
   if(copied < count)
   {
      if(DebugMode)
         Print("CopyBuffer failed handle=", handle, " buffer=", buffer, " copied=", copied);
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
bool IsOurPosition(ulong ticket)
{
   if(ticket == 0)
      return false;
   if(PositionGetString(POSITION_SYMBOL) != _Symbol)
      return false;
   if(PositionGetInteger(POSITION_MAGIC) != MAGIC)
      return false;
   return true;
}

//+------------------------------------------------------------------+
int CountOurPositions()
{
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(IsOurPosition(ticket))
         n++;
   }
   return n;
}

//+------------------------------------------------------------------+
int CountOurPositionsByType(int direction)
{
   int n = 0;
   long wanted = (direction == 1) ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!IsOurPosition(ticket))
         continue;
      if(PositionGetInteger(POSITION_TYPE) == wanted)
         n++;
   }
   return n;
}

//+------------------------------------------------------------------+
double RecentRangePips(int bars)
{
   int count = MathMax(2, bars);
   int hi = iHighest(_Symbol, PERIOD_M1, MODE_HIGH, count, 1);
   int lo = iLowest(_Symbol, PERIOD_M1, MODE_LOW, count, 1);
   if(hi < 0 || lo < 0)
      return 0.0;

   double high = iHigh(_Symbol, PERIOD_M1, hi);
   double low  = iLow(_Symbol, PERIOD_M1, lo);
   return (high - low) / PipSize;
}

//+------------------------------------------------------------------+
double NormLot(double lot)
{
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double mn   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double mx   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   if(step <= 0.0)
      step = 0.01;

   lot = MathFloor(lot / step) * step;
   return MathMax(mn, MathMin(mx, lot));
}

//+------------------------------------------------------------------+
double CalcPipSize()
{
   if(_Digits == 3 || _Digits == 5)
      return _Point * 10.0;
   return _Point;
}

//+------------------------------------------------------------------+
string DirStr(int d)
{
   if(d == 1)
      return "BUY";
   if(d == -1)
      return "SELL";
   return "NEUTRAL";
}
//+------------------------------------------------------------------+
