//+------------------------------------------------------------------+
//|                 XAUUSD_M1_TickScalper_Pro.mq5                    |
//|  Microtick impulse basket scalper: strict M1 indicators + ticks   |
//+------------------------------------------------------------------+
#property copyright "2026 AndroindDeve + AI"
#property version   "2.00"
#property strict

#include <Trade\Trade.mqh>
CTrade trade;

//=== Inputs ==========================================================

input group "Basket risk"
input double BaseLot                    = 0.01;
input int    MaxBasketPositions         = 10;
input double MaxLotPerBasket            = 0.10;
input double BasketProfitTargetMoney    = 2.0;
input double BasketMinCloseProfitMoney  = 0.20;
input double MaxLossPctPerPosition      = 10.0;   // Close each position if its loss reaches this % of balance
input int    MaxTotalPositions          = 10;

input group "Microtick entry"
input int    TickLookback               = 8;
input double MinImpulsePips             = 1.2;
input double MinImpulseAtrPart          = 0.06;
input int    MinEntryScore              = 7;
input int    StrongEntryScore           = 11;
input int    MediumEntryPositions       = 5;
input int    StrongEntryPositions       = 10;
input int    MinSecondsBetweenBaskets   = 2;
input int    MinSecondsBetweenAdds      = 1;
input bool   AddWhileImpulseContinues   = true;

input group "Basket exit"
input int    ReverseExitScore           = 7;
input double FadeVelocityPipsPerSec     = 0.03;
input double ReverseTickPips            = 0.8;
input bool   FlipOnStrongReverse        = true;
input int    CooldownAfterCloseSeconds  = 1;

input group "Session"
input int    GMT_Offset                 = 3;
input int    Session_Start_H            = 7;
input int    Session_End_H              = 21;

input group "Strict M1 indicators"
input int    EMA_Fast_Period            = 9;
input int    EMA_Micro_Period           = 21;
input int    RSI_Period                 = 7;
input int    Stoch_K                    = 5;
input int    Stoch_D                    = 3;
input int    Stoch_Slowing              = 3;
input int    ATR_Period                 = 14;
input int    BB_Period                  = 20;
input double BB_Deviation               = 2.0;
input int    MFI_Period                 = 7;
input int    VWAP_Bars                  = 20;

input group "Execution"
input int    DeviationPoints            = 80;
input bool   DebugMode                  = true;

//=== Handles =========================================================
int h_ema_fast = INVALID_HANDLE;
int h_ema_micro = INVALID_HANDLE;
int h_rsi = INVALID_HANDLE;
int h_stoch = INVALID_HANDLE;
int h_atr = INVALID_HANDLE;
int h_bbands = INVALID_HANDLE;
int h_mfi = INVALID_HANDLE;

//=== Globals =========================================================
long     MAGIC = 202604282;
double   PipSize = 0.0;
datetime last_basket_time = 0;
datetime last_add_time = 0;
datetime last_close_time = 0;
datetime last_log_bar = 0;

#define TICK_BUFFER_SIZE 32
double   tick_prices[TICK_BUFFER_SIZE];
datetime tick_times[TICK_BUFFER_SIZE];
int      tick_dirs[TICK_BUFFER_SIZE];
int      tick_filled = 0;
double   tick_velocity = 0.0;

struct MicroSignal
{
   int    direction;
   int    score;
   int    positions;
   double spread_pips;
   double impulse_pips;
   double atr_pips;
   string reason;
};

//+------------------------------------------------------------------+
int OnInit()
{
   PipSize = CalcPipSize();
   ArrayInitialize(tick_prices, 0.0);
   ArrayInitialize(tick_times, 0);
   ArrayInitialize(tick_dirs, 0);

   h_ema_fast  = iMA(_Symbol, PERIOD_M1, EMA_Fast_Period, 0, MODE_EMA, PRICE_CLOSE);
   h_ema_micro = iMA(_Symbol, PERIOD_M1, EMA_Micro_Period, 0, MODE_EMA, PRICE_CLOSE);
   h_rsi       = iRSI(_Symbol, PERIOD_M1, RSI_Period, PRICE_CLOSE);
   h_stoch     = iStochastic(_Symbol, PERIOD_M1, Stoch_K, Stoch_D, Stoch_Slowing, MODE_SMA, STO_LOWHIGH);
   h_atr       = iATR(_Symbol, PERIOD_M1, ATR_Period);
   h_bbands    = iBands(_Symbol, PERIOD_M1, BB_Period, 0, BB_Deviation, PRICE_CLOSE);
   h_mfi       = iMFI(_Symbol, PERIOD_M1, MFI_Period, VOLUME_TICK);

   if(h_ema_fast == INVALID_HANDLE || h_ema_micro == INVALID_HANDLE ||
      h_rsi == INVALID_HANDLE || h_stoch == INVALID_HANDLE ||
      h_atr == INVALID_HANDLE || h_bbands == INVALID_HANDLE ||
      h_mfi == INVALID_HANDLE)
   {
      Print("Init failed: every indicator must be available on PERIOD_M1.");
      return INIT_FAILED;
   }

   trade.SetExpertMagicNumber(MAGIC);
   trade.SetDeviationInPoints(DeviationPoints);
   trade.SetAsyncMode(false);

   Print("XAUUSD M1 TickScalper Pro v2.00 started. Microtick baskets, no SL/TP, per-position -",
         DoubleToString(MaxLossPctPerPosition, 1), "% protection.");
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(h_ema_fast);
   IndicatorRelease(h_ema_micro);
   IndicatorRelease(h_rsi);
   IndicatorRelease(h_stoch);
   IndicatorRelease(h_atr);
   IndicatorRelease(h_bbands);
   IndicatorRelease(h_mfi);
}

//+------------------------------------------------------------------+
void OnTick()
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0.0 || bid <= 0.0 || ask <= bid)
      return;

   UpdateTickBuffer(bid);
   ClosePositionsAtIndividualLoss();

   MicroSignal sig = BuildMicroSignal(ask, bid);
   ManageBasket(sig);

   if(!IsTradingSession())
      return;

   if(CountOurPositions() >= MaxTotalPositions)
      return;

   int basket_dir = BasketDirection();
   if(basket_dir == 0)
   {
      if(TimeCurrent() - last_basket_time < MinSecondsBetweenBaskets)
         return;
      if(TimeCurrent() - last_close_time < CooldownAfterCloseSeconds)
         return;
      if(sig.direction != 0)
         OpenBasket(sig, ask, bid);
      else
         LogOncePerBar("WAIT " + sig.reason);
      return;
   }

   if(AddWhileImpulseContinues &&
      sig.direction == basket_dir &&
      sig.score >= StrongEntryScore &&
      TimeCurrent() - last_add_time >= MinSecondsBetweenAdds)
   {
      AddToBasket(sig, ask, bid);
   }
}

//+------------------------------------------------------------------+
MicroSignal EmptySignal(string reason)
{
   MicroSignal sig;
   sig.direction = 0;
   sig.score = 0;
   sig.positions = 0;
   sig.spread_pips = 0.0;
   sig.impulse_pips = 0.0;
   sig.atr_pips = 0.0;
   sig.reason = reason;
   return sig;
}

//+------------------------------------------------------------------+
MicroSignal BuildMicroSignal(double ask, double bid)
{
   double ema_fast[], ema_micro[], rsi[], atr[], stoch_k[], stoch_d[];
   double bb_up[], bb_mid[], bb_low[], mfi[];

   if(!SafeCopy(h_ema_fast,  0, ema_fast,  4)) return EmptySignal("EMA fast data missing");
   if(!SafeCopy(h_ema_micro, 0, ema_micro, 4)) return EmptySignal("EMA micro data missing");
   if(!SafeCopy(h_rsi,       0, rsi,       4)) return EmptySignal("RSI data missing");
   if(!SafeCopy(h_atr,       0, atr,       4)) return EmptySignal("ATR data missing");
   if(!SafeCopy(h_stoch,     0, stoch_k,   4)) return EmptySignal("Stoch K data missing");
   if(!SafeCopy(h_stoch,     1, stoch_d,   4)) return EmptySignal("Stoch D data missing");
   if(!SafeCopy(h_bbands,    0, bb_up,     4)) return EmptySignal("BB upper data missing");
   if(!SafeCopy(h_bbands,    1, bb_mid,    4)) return EmptySignal("BB middle data missing");
   if(!SafeCopy(h_bbands,    2, bb_low,    4)) return EmptySignal("BB lower data missing");
   if(!SafeCopy(h_mfi,       0, mfi,       4)) return EmptySignal("MFI data missing");

   double price = (ask + bid) * 0.5;
   double atr_pips = atr[1] / PipSize;
   if(atr_pips <= 0.0)
      return EmptySignal("ATR zero");

   double impulse = RecentTickMovePips(TickLookback);
   double needed_impulse = MathMax(MinImpulsePips, atr_pips * MinImpulseAtrPart);
   double spread_pips = (ask - bid) / PipSize;

   int buy_score = 0;
   int sell_score = 0;
   string buy_reason = "";
   string sell_reason = "";

   ScoreTickImpulse(impulse, needed_impulse, buy_score, sell_score, buy_reason, sell_reason);
   ScoreCurrentM1Candle(buy_score, sell_score, buy_reason, sell_reason);
   ScoreMicroIndicators(price, ema_fast, ema_micro, rsi[0], stoch_k, stoch_d,
                        bb_mid[0], bb_up[0], bb_low[0], mfi[0],
                        buy_score, sell_score, buy_reason, sell_reason);

   double vwap = CalcRecentVWAP(VWAP_Bars);
   if(vwap > 0.0)
   {
      if(price > vwap) { buy_score++; buy_reason += "above_VWAP "; }
      if(price < vwap) { sell_score++; sell_reason += "below_VWAP "; }
   }

   int direction = 0;
   int score = 0;
   string reason = "";
   if(buy_score >= sell_score + 2)
   {
      direction = 1;
      score = buy_score;
      reason = buy_reason;
   }
   else if(sell_score >= buy_score + 2)
   {
      direction = -1;
      score = sell_score;
      reason = sell_reason;
   }
   else
   {
      return EmptySignal("mixed micro score buy=" + IntegerToString(buy_score) +
                         " sell=" + IntegerToString(sell_score) +
                         " impulse=" + DoubleToString(impulse, 1));
   }

   if(score < MinEntryScore)
      return EmptySignal("score low " + DirStr(direction) + "=" + IntegerToString(score) +
                         " impulse=" + DoubleToString(impulse, 1));

   int positions = MediumEntryPositions;
   if(score >= StrongEntryScore)
      positions = StrongEntryPositions;

   int lot_cap = (int)MathFloor(MaxLotPerBasket / BaseLot);
   positions = MathMin(positions, MathMax(1, lot_cap));
   positions = MathMin(positions, MaxBasketPositions);
   positions = MathMin(positions, MaxTotalPositions - CountOurPositions());

   if(positions <= 0)
      return EmptySignal("no position capacity");

   MicroSignal sig;
   sig.direction = direction;
   sig.score = score;
   sig.positions = positions;
   sig.spread_pips = spread_pips;
   sig.impulse_pips = impulse;
   sig.atr_pips = atr_pips;
   sig.reason = reason +
                "score=" + IntegerToString(score) +
                " impulse=" + DoubleToString(impulse, 1) +
                "p atr=" + DoubleToString(atr_pips, 1) +
                "p spread=" + DoubleToString(spread_pips, 1) + "p";
   return sig;
}

//+------------------------------------------------------------------+
void ScoreTickImpulse(double impulse, double needed,
                      int &buy_score, int &sell_score,
                      string &buy_reason, string &sell_reason)
{
   int up_ticks = CountRecentDirections(1, TickLookback);
   int down_ticks = CountRecentDirections(-1, TickLookback);

   if(impulse >= needed)
   {
      buy_score += 4;
      buy_reason += "tick_impulse_up ";
      if(up_ticks >= MathMax(3, TickLookback / 2))
      {
         buy_score += 2;
         buy_reason += "ticks_stack_up ";
      }
      if(tick_velocity > FadeVelocityPipsPerSec)
      {
         buy_score += 2;
         buy_reason += "velocity_up ";
      }
   }
   else if(impulse <= -needed)
   {
      sell_score += 4;
      sell_reason += "tick_impulse_down ";
      if(down_ticks >= MathMax(3, TickLookback / 2))
      {
         sell_score += 2;
         sell_reason += "ticks_stack_down ";
      }
      if(tick_velocity < -FadeVelocityPipsPerSec)
      {
         sell_score += 2;
         sell_reason += "velocity_down ";
      }
   }
}

//+------------------------------------------------------------------+
void ScoreCurrentM1Candle(int &buy_score, int &sell_score,
                          string &buy_reason, string &sell_reason)
{
   double open0 = iOpen(_Symbol, PERIOD_M1, 0);
   double close0 = iClose(_Symbol, PERIOD_M1, 0);
   if(open0 <= 0.0 || close0 <= 0.0)
      return;

   double body_pips = (close0 - open0) / PipSize;
   if(body_pips > 0.5)
   {
      buy_score += 2;
      buy_reason += "M1_body_up ";
   }
   else if(body_pips < -0.5)
   {
      sell_score += 2;
      sell_reason += "M1_body_down ";
   }
}

//+------------------------------------------------------------------+
void ScoreMicroIndicators(double price,
                          double &ema_fast[], double &ema_micro[],
                          double rsi_value,
                          double &stoch_k[], double &stoch_d[],
                          double bb_mid, double bb_up, double bb_low,
                          double mfi_value,
                          int &buy_score, int &sell_score,
                          string &buy_reason, string &sell_reason)
{
   if(ema_fast[0] > ema_micro[0]) { buy_score += 1; buy_reason += "EMA_micro_up "; }
   if(ema_fast[0] < ema_micro[0]) { sell_score += 1; sell_reason += "EMA_micro_down "; }

   double ema_slope = (ema_fast[0] - ema_fast[2]) / PipSize;
   if(ema_slope > 0.3) { buy_score += 1; buy_reason += "EMA_slope_up "; }
   if(ema_slope < -0.3) { sell_score += 1; sell_reason += "EMA_slope_down "; }

   if(rsi_value > 52.0 && rsi_value < 78.0) { buy_score += 1; buy_reason += "RSI_up "; }
   if(rsi_value < 48.0 && rsi_value > 22.0) { sell_score += 1; sell_reason += "RSI_down "; }

   if(stoch_k[0] > stoch_d[0] && stoch_k[0] < 90.0) { buy_score += 1; buy_reason += "Stoch_up "; }
   if(stoch_k[0] < stoch_d[0] && stoch_k[0] > 10.0) { sell_score += 1; sell_reason += "Stoch_down "; }

   if(price > bb_mid && price < bb_up) { buy_score += 1; buy_reason += "BB_up_side "; }
   if(price < bb_mid && price > bb_low) { sell_score += 1; sell_reason += "BB_down_side "; }

   if(mfi_value > 50.0 && mfi_value < 85.0) { buy_score += 1; buy_reason += "MFI_buy_flow "; }
   if(mfi_value < 50.0 && mfi_value > 15.0) { sell_score += 1; sell_reason += "MFI_sell_flow "; }
}

//+------------------------------------------------------------------+
void ManageBasket(MicroSignal &sig)
{
   int basket_dir = BasketDirection();
   if(basket_dir == 0)
      return;

   double profit = BasketProfit();
   if(profit >= BasketProfitTargetMoney)
   {
      CloseBasket("basket target profit=" + DoubleToString(profit, 2));
      return;
   }

   bool reverse = (sig.direction == -basket_dir && sig.score >= ReverseExitScore);
   bool fade = IsImpulseFadingAgainstBasket(basket_dir);
   if(profit >= BasketMinCloseProfitMoney && (reverse || fade))
   {
      CloseBasket((reverse ? "reverse impulse " : "fade impulse ") +
                  "profit=" + DoubleToString(profit, 2));
      if(reverse && FlipOnStrongReverse && IsTradingSession())
         OpenBasket(sig, SymbolInfoDouble(_Symbol, SYMBOL_ASK), SymbolInfoDouble(_Symbol, SYMBOL_BID));
   }
}

//+------------------------------------------------------------------+
bool IsImpulseFadingAgainstBasket(int basket_dir)
{
   double impulse = RecentTickMovePips(MathMax(3, TickLookback / 2));
   if(basket_dir == 1)
      return (tick_velocity < FadeVelocityPipsPerSec && impulse <= -ReverseTickPips);
   if(basket_dir == -1)
      return (tick_velocity > -FadeVelocityPipsPerSec && impulse >= ReverseTickPips);
   return false;
}

//+------------------------------------------------------------------+
void OpenBasket(MicroSignal &sig, double ask, double bid)
{
   if(sig.direction == 0 || sig.positions <= 0)
      return;

   int opened = SendMarketOrders(sig.direction, sig.positions, ask, bid, "micro basket");
   if(opened > 0)
   {
      last_basket_time = TimeCurrent();
      last_add_time = TimeCurrent();
      Print("OPEN_BASKET ", opened, " ", DirStr(sig.direction), " | ", sig.reason);
   }
}

//+------------------------------------------------------------------+
void AddToBasket(MicroSignal &sig, double ask, double bid)
{
   int side_count = CountPositionsByDirection(sig.direction);
   int capacity = MathMin(MaxBasketPositions, MaxTotalPositions) - side_count;
   if(capacity <= 0)
      return;

   int add_count = MathMin(sig.positions, capacity);
   int opened = SendMarketOrders(sig.direction, add_count, ask, bid, "micro add");
   if(opened > 0)
   {
      last_add_time = TimeCurrent();
      Print("ADD_BASKET ", opened, " ", DirStr(sig.direction), " | ", sig.reason);
   }
}

//+------------------------------------------------------------------+
int SendMarketOrders(int direction, int count, double ask, double bid, string comment)
{
   int opened = 0;
   double lot = NormLot(BaseLot);

   for(int i = 0; i < count; i++)
   {
      ResetLastError();
      bool ok = false;
      if(direction == 1)
         ok = trade.Buy(lot, _Symbol, ask, 0.0, 0.0, comment + " buy");
      else
         ok = trade.Sell(lot, _Symbol, bid, 0.0, 0.0, comment + " sell");

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

   return opened;
}

//+------------------------------------------------------------------+
void CloseBasket(string reason)
{
   Print("CLOSE_BASKET ", reason);
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!IsOurPosition(ticket))
         continue;

      double profit = PositionGetDouble(POSITION_PROFIT);
      if(trade.PositionClose(ticket))
         Print("closed ticket=", ticket, " profit=", DoubleToString(profit, 2));
   }
   last_close_time = TimeCurrent();
}

//+------------------------------------------------------------------+
void ClosePositionsAtIndividualLoss()
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double max_loss = balance * MaxLossPctPerPosition / 100.0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!IsOurPosition(ticket))
         continue;

      double profit = PositionGetDouble(POSITION_PROFIT);
      if(profit < 0.0 && MathAbs(profit) >= max_loss)
      {
         if(trade.PositionClose(ticket))
            Print("INDIVIDUAL_LOSS_CLOSE ticket=", ticket,
                  " profit=", DoubleToString(profit, 2),
                  " limit=", DoubleToString(max_loss, 2));
      }
   }
}

//+------------------------------------------------------------------+
void UpdateTickBuffer(double bid)
{
   double prev = tick_prices[0];
   datetime prev_time = tick_times[0];

   for(int i = TICK_BUFFER_SIZE - 1; i > 0; i--)
   {
      tick_prices[i] = tick_prices[i - 1];
      tick_times[i] = tick_times[i - 1];
      tick_dirs[i] = tick_dirs[i - 1];
   }

   tick_prices[0] = bid;
   tick_times[0] = TimeCurrent();
   if(prev > 0.0)
      tick_dirs[0] = (bid > prev) ? 1 : ((bid < prev) ? -1 : 0);
   else
      tick_dirs[0] = 0;

   if(tick_filled < TICK_BUFFER_SIZE)
      tick_filled++;

   int seconds = 1;
   if(prev_time > 0)
      seconds = (int)MathMax(1, tick_times[0] - prev_time);
   tick_velocity = (prev > 0.0) ? ((bid - prev) / PipSize / seconds) : 0.0;
}

//+------------------------------------------------------------------+
double RecentTickMovePips(int lookback)
{
   int idx = MathMin(MathMax(1, lookback), tick_filled - 1);
   if(idx <= 0 || tick_prices[idx] <= 0.0)
      return 0.0;
   return (tick_prices[0] - tick_prices[idx]) / PipSize;
}

//+------------------------------------------------------------------+
int CountRecentDirections(int direction, int lookback)
{
   int count = 0;
   int max_i = MathMin(lookback, tick_filled);
   for(int i = 0; i < max_i; i++)
   {
      if(tick_dirs[i] == direction)
         count++;
   }
   return count;
}

//+------------------------------------------------------------------+
double BasketProfit()
{
   double profit = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(IsOurPosition(ticket))
         profit += PositionGetDouble(POSITION_PROFIT);
   }
   return profit;
}

//+------------------------------------------------------------------+
int BasketDirection()
{
   int buy_count = CountPositionsByDirection(1);
   int sell_count = CountPositionsByDirection(-1);
   if(buy_count > 0 && sell_count == 0)
      return 1;
   if(sell_count > 0 && buy_count == 0)
      return -1;
   return 0;
}

//+------------------------------------------------------------------+
double CalcRecentVWAP(int bars)
{
   int count = MathMax(2, bars);
   double pv = 0.0;
   double vol = 0.0;

   for(int i = 0; i < count; i++)
   {
      double high = iHigh(_Symbol, PERIOD_M1, i);
      double low = iLow(_Symbol, PERIOD_M1, i);
      double close = iClose(_Symbol, PERIOD_M1, i);
      long tick_vol = iVolume(_Symbol, PERIOD_M1, i);
      if(high <= 0.0 || low <= 0.0 || close <= 0.0 || tick_vol <= 0)
         continue;

      double typical = (high + low + close) / 3.0;
      pv += typical * (double)tick_vol;
      vol += (double)tick_vol;
   }

   if(vol <= 0.0)
      return 0.0;
   return pv / vol;
}

//+------------------------------------------------------------------+
bool SafeCopy(int handle, int buffer, double &arr[], int count)
{
   if(handle == INVALID_HANDLE)
      return false;

   ArraySetAsSeries(arr, true);
   int copied = CopyBuffer(handle, buffer, 0, count, arr);
   return copied >= count;
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
   int total = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(IsOurPosition(ticket))
         total++;
   }
   return total;
}

//+------------------------------------------------------------------+
int CountPositionsByDirection(int direction)
{
   int total = 0;
   long wanted = (direction == 1) ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!IsOurPosition(ticket))
         continue;
      if(PositionGetInteger(POSITION_TYPE) == wanted)
         total++;
   }
   return total;
}

//+------------------------------------------------------------------+
double NormLot(double lot)
{
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double min_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double max_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   if(step <= 0.0)
      step = 0.01;

   lot = MathFloor(lot / step) * step;
   return MathMax(min_lot, MathMin(max_lot, lot));
}

//+------------------------------------------------------------------+
double CalcPipSize()
{
   if(_Digits == 3 || _Digits == 5)
      return _Point * 10.0;
   return _Point;
}

//+------------------------------------------------------------------+
void LogOncePerBar(string message)
{
   if(!DebugMode)
      return;

   datetime bar = iTime(_Symbol, PERIOD_M1, 0);
   if(bar == last_log_bar)
      return;

   last_log_bar = bar;
   Print(message);
}

//+------------------------------------------------------------------+
string DirStr(int direction)
{
   if(direction == 1)
      return "BUY";
   if(direction == -1)
      return "SELL";
   return "NEUTRAL";
}
//+------------------------------------------------------------------+
