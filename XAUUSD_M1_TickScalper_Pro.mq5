//+------------------------------------------------------------------+
//|                 XAUUSD_M1_TickScalper_Pro.mq5                    |
//|  Fresh strict-M1 XAUUSD scalper: M1 context + every-tick control  |
//+------------------------------------------------------------------+
#property copyright "2026 AndroindDeve + AI"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
CTrade trade;

//=== Inputs ==========================================================

input group "Risk and exits"
input double BaseLot                 = 0.01;
input double MaxLotPerSignal         = 0.05;
input double ProfitTargetMoney       = 1.5;
input double MaxLossPctPerPosition   = 2.0;
input bool   UseDynamicTP            = true;
input double TP_ATR_Mult             = 0.55;
input bool   UseATR_SL               = true;
input double SL_ATR_Mult             = 1.30;
input double FixedSL_Pips            = 30.0;

input group "Trailing"
input bool   UseTrailing             = true;
input double TrailStart_ATR_Mult     = 0.35;
input double TrailStep_ATR_Mult      = 0.18;
input double TrailStart_MinPips      = 6.0;
input double TrailStep_MinPips       = 3.0;

input group "Entry control"
input int    MinScoreToEnter         = 7;
input int    WeakSignal_Positions    = 1;
input int    StrongSignal_Positions  = 2;
input int    MaxTotalPositions       = 10;
input int    MaxPositionsPerSide     = 5;
input int    MinSecondsBetweenTrades = 5;
input bool   AllowOppositeHedge      = false;
input int    DeviationPoints         = 50;

input group "Session"
input int    GMT_Offset              = 3;
input int    Session_Start_H         = 7;
input int    Session_End_H           = 21;

input group "Strict M1 indicators"
input int    EMA_Fast_Period         = 9;
input int    EMA_Slow_Period         = 21;
input int    EMA_Trend_Period        = 50;
input int    EMA_Slope_Bars          = 3;
input int    RSI_Period              = 14;
input int    ADX_Period              = 14;
input double ADX_Min                 = 14.0;
input int    ATR_Period              = 14;
input int    MACD_Fast               = 12;
input int    MACD_Slow               = 26;
input int    MACD_Signal             = 9;
input int    Stoch_K                 = 5;
input int    Stoch_D                 = 3;
input int    Stoch_Slowing           = 3;
input int    BB_Period               = 20;
input double BB_Deviation            = 2.0;
input int    MFI_Period              = 14;
input int    VWAP_Bars               = 30;
input int    MicroRange_Bars         = 5;
input double MinMicroRange_Pips      = 2.0;

input group "Spread accounting, never blocking"
input double SpreadAtrReduce_1       = 0.35;
input double SpreadAtrReduce_2       = 0.70;
input double SpreadAtrScorePenalty   = 0.90;

input group "Debug"
input bool   DebugMode               = true;

//=== Handles =========================================================
int h_ema_fast  = INVALID_HANDLE;
int h_ema_slow  = INVALID_HANDLE;
int h_ema_trend = INVALID_HANDLE;
int h_rsi       = INVALID_HANDLE;
int h_adx       = INVALID_HANDLE;
int h_atr       = INVALID_HANDLE;
int h_macd      = INVALID_HANDLE;
int h_stoch     = INVALID_HANDLE;
int h_bbands    = INVALID_HANDLE;
int h_mfi       = INVALID_HANDLE;

//=== Globals =========================================================
long     MAGIC             = 202604281;
double   PipSize           = 0.0;
datetime last_trade_time   = 0;
datetime last_log_bar      = 0;
double   last_bid_seen     = 0.0;
datetime last_tick_seen    = 0;
double   tick_velocity     = 0.0;

struct SignalData
{
   int    direction;
   int    score;
   int    positions;
   double sl;
   double tp;
   string reason;
};

//+------------------------------------------------------------------+
int OnInit()
{
   PipSize = CalcPipSize();

   h_ema_fast  = iMA(_Symbol, PERIOD_M1, EMA_Fast_Period, 0, MODE_EMA, PRICE_CLOSE);
   h_ema_slow  = iMA(_Symbol, PERIOD_M1, EMA_Slow_Period, 0, MODE_EMA, PRICE_CLOSE);
   h_ema_trend = iMA(_Symbol, PERIOD_M1, EMA_Trend_Period, 0, MODE_EMA, PRICE_CLOSE);
   h_rsi       = iRSI(_Symbol, PERIOD_M1, RSI_Period, PRICE_CLOSE);
   h_adx       = iADX(_Symbol, PERIOD_M1, ADX_Period);
   h_atr       = iATR(_Symbol, PERIOD_M1, ATR_Period);
   h_macd      = iMACD(_Symbol, PERIOD_M1, MACD_Fast, MACD_Slow, MACD_Signal, PRICE_CLOSE);
   h_stoch     = iStochastic(_Symbol, PERIOD_M1, Stoch_K, Stoch_D, Stoch_Slowing, MODE_SMA, STO_LOWHIGH);
   h_bbands    = iBands(_Symbol, PERIOD_M1, BB_Period, 0, BB_Deviation, PRICE_CLOSE);
   h_mfi       = iMFI(_Symbol, PERIOD_M1, MFI_Period, VOLUME_TICK);

   if(h_ema_fast  == INVALID_HANDLE || h_ema_slow == INVALID_HANDLE ||
      h_ema_trend == INVALID_HANDLE || h_rsi      == INVALID_HANDLE ||
      h_adx       == INVALID_HANDLE || h_atr      == INVALID_HANDLE ||
      h_macd      == INVALID_HANDLE || h_stoch    == INVALID_HANDLE ||
      h_bbands    == INVALID_HANDLE || h_mfi      == INVALID_HANDLE)
   {
      Print("Init failed: every indicator must be available on PERIOD_M1.");
      return INIT_FAILED;
   }

   trade.SetExpertMagicNumber(MAGIC);
   trade.SetDeviationInPoints(DeviationPoints);
   trade.SetAsyncMode(false);

   Print("XAUUSD M1 TickScalper Pro v1.00 started. No spread entry block. All indicators PERIOD_M1.");
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(h_ema_fast);
   IndicatorRelease(h_ema_slow);
   IndicatorRelease(h_ema_trend);
   IndicatorRelease(h_rsi);
   IndicatorRelease(h_adx);
   IndicatorRelease(h_atr);
   IndicatorRelease(h_macd);
   IndicatorRelease(h_stoch);
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

   UpdateTickVelocity(bid);
   ManagePositions();
   ApplyTrailing();

   if(!IsTradingSession())
      return;

   if(CountOurPositions() >= MaxTotalPositions)
      return;

   if(TimeCurrent() - last_trade_time < MinSecondsBetweenTrades)
      return;

   SignalData sig = BuildSignal(ask, bid);
   if(sig.direction == 0)
   {
      LogOncePerBar("No entry: " + sig.reason);
      return;
   }

   ExecuteSignal(sig, ask, bid);
}

//+------------------------------------------------------------------+
SignalData EmptySignal(string reason)
{
   SignalData s;
   s.direction = 0;
   s.score     = 0;
   s.positions = 0;
   s.sl        = 0.0;
   s.tp        = 0.0;
   s.reason    = reason;
   return s;
}

//+------------------------------------------------------------------+
SignalData BuildSignal(double ask, double bid)
{
   double ema_fast[], ema_slow[], ema_trend[];
   double rsi[], atr[];
   double adx_main[], adx_plus[], adx_minus[];
   double macd_main[], macd_signal[];
   double stoch_k[], stoch_d[];
   double bb_up[], bb_mid[], bb_low[];
   double mfi[];

   int ema_need = MathMax(EMA_Slope_Bars + 3, 6);
   if(!SafeCopy(h_ema_fast,  0, ema_fast,   ema_need)) return EmptySignal("EMA fast data missing");
   if(!SafeCopy(h_ema_slow,  0, ema_slow,   ema_need)) return EmptySignal("EMA slow data missing");
   if(!SafeCopy(h_ema_trend, 0, ema_trend,  ema_need)) return EmptySignal("EMA trend data missing");
   if(!SafeCopy(h_rsi,       0, rsi,        5))        return EmptySignal("RSI data missing");
   if(!SafeCopy(h_atr,       0, atr,        5))        return EmptySignal("ATR data missing");
   if(!SafeCopy(h_adx,       0, adx_main,   5))        return EmptySignal("ADX data missing");
   if(!SafeCopy(h_adx,       1, adx_plus,   5))        return EmptySignal("DI plus data missing");
   if(!SafeCopy(h_adx,       2, adx_minus,  5))        return EmptySignal("DI minus data missing");
   if(!SafeCopy(h_macd,      0, macd_main,  5))        return EmptySignal("MACD data missing");
   if(!SafeCopy(h_macd,      1, macd_signal,5))        return EmptySignal("MACD signal data missing");
   if(!SafeCopy(h_stoch,     0, stoch_k,    5))        return EmptySignal("Stoch K data missing");
   if(!SafeCopy(h_stoch,     1, stoch_d,    5))        return EmptySignal("Stoch D data missing");
   if(!SafeCopy(h_bbands,    0, bb_up,      5))        return EmptySignal("BB upper data missing");
   if(!SafeCopy(h_bbands,    1, bb_mid,     5))        return EmptySignal("BB middle data missing");
   if(!SafeCopy(h_bbands,    2, bb_low,     5))        return EmptySignal("BB lower data missing");
   if(!SafeCopy(h_mfi,       0, mfi,        5))        return EmptySignal("MFI data missing");

   double price = (ask + bid) * 0.5;
   double spread = ask - bid;
   double spread_pips = spread / PipSize;
   double atr_now = atr[1];
   if(atr_now <= 0.0)
      return EmptySignal("ATR is zero");

   double micro_range = RecentRangePips(MicroRange_Bars);
   if(micro_range < MinMicroRange_Pips)
      return EmptySignal("micro range low " + DoubleToString(micro_range, 1));

   double vwap = CalcRecentVWAP(VWAP_Bars);
   if(vwap <= 0.0)
      vwap = bb_mid[1];

   int buy_score = 0;
   int sell_score = 0;
   string buy_reason = "";
   string sell_reason = "";

   ScoreEma(price, ema_fast, ema_slow, ema_trend, buy_score, sell_score, buy_reason, sell_reason);
   ScoreAdx(adx_main, adx_plus, adx_minus, buy_score, sell_score, buy_reason, sell_reason);
   ScoreMacd(macd_main, macd_signal, buy_score, sell_score, buy_reason, sell_reason);
   ScoreRsi(rsi[1], buy_score, sell_score, buy_reason, sell_reason);
   ScoreStoch(stoch_k, stoch_d, buy_score, sell_score, buy_reason, sell_reason);
   ScoreBandsAndVwap(price, bb_mid[1], bb_up[1], bb_low[1], vwap, buy_score, sell_score, buy_reason, sell_reason);
   ScoreMfi(mfi[1], buy_score, sell_score, buy_reason, sell_reason);
   ScoreTickImpulse(buy_score, sell_score, buy_reason, sell_reason);

   double spread_atr = spread / atr_now;
   if(spread_atr >= SpreadAtrScorePenalty)
   {
      buy_score--;
      sell_score--;
      buy_reason += "spread_heavy ";
      sell_reason += "spread_heavy ";
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
      return EmptySignal("mixed signal buy=" + IntegerToString(buy_score) +
                         " sell=" + IntegerToString(sell_score) +
                         " spread=" + DoubleToString(spread_pips, 1));
   }

   if(score < MinScoreToEnter)
      return EmptySignal("score low " + DirStr(direction) + "=" + IntegerToString(score));

   if(!AllowOppositeHedge && CountOppositePositions(direction) > 0)
      return EmptySignal("opposite position exists");

   int side_count = CountPositionsByDirection(direction);
   if(side_count >= MaxPositionsPerSide)
      return EmptySignal("side limit reached");

   int positions = (score >= MinScoreToEnter + 3) ? StrongSignal_Positions : WeakSignal_Positions;
   int lot_cap = (int)MathFloor(MaxLotPerSignal / BaseLot);
   positions = MathMin(positions, MathMax(1, lot_cap));
   positions = MathMin(positions, MaxPositionsPerSide - side_count);

   if(spread_atr >= SpreadAtrReduce_2)
      positions = MathMax(1, positions - 2);
   else if(spread_atr >= SpreadAtrReduce_1)
      positions = MathMax(1, positions - 1);

   SignalData sig;
   sig.direction = direction;
   sig.score     = score;
   sig.positions = positions;
   sig.sl        = CalcSL(direction, atr_now, ask, bid);
   sig.tp        = CalcTP(direction, atr_now, ask, bid);
   sig.reason    = reason +
                   "score=" + IntegerToString(score) +
                   " spread=" + DoubleToString(spread_pips, 1) +
                   "p spreadATR=" + DoubleToString(spread_atr, 2) +
                   " vwap=" + DoubleToString(vwap, _Digits);
   return sig;
}

//+------------------------------------------------------------------+
void ScoreEma(double price,
              double &ema_fast[], double &ema_slow[], double &ema_trend[],
              int &buy_score, int &sell_score,
              string &buy_reason, string &sell_reason)
{
   double fast_slope = (ema_fast[1] - ema_fast[1 + EMA_Slope_Bars]) / PipSize;
   double slow_slope = (ema_slow[1] - ema_slow[1 + EMA_Slope_Bars]) / PipSize;

   if(ema_fast[1] > ema_slow[1]) { buy_score += 2; buy_reason += "EMA_fast>slow "; }
   if(ema_fast[1] < ema_slow[1]) { sell_score += 2; sell_reason += "EMA_fast<slow "; }

   if(price > ema_fast[0] && price > ema_trend[0]) { buy_score += 2; buy_reason += "price_above_EMA "; }
   if(price < ema_fast[0] && price < ema_trend[0]) { sell_score += 2; sell_reason += "price_below_EMA "; }

   if(fast_slope > 1.0 && slow_slope >= 0.0) { buy_score += 2; buy_reason += "EMA_slope_up "; }
   if(fast_slope < -1.0 && slow_slope <= 0.0) { sell_score += 2; sell_reason += "EMA_slope_down "; }
}

//+------------------------------------------------------------------+
void ScoreAdx(double &adx_main[], double &adx_plus[], double &adx_minus[],
              int &buy_score, int &sell_score,
              string &buy_reason, string &sell_reason)
{
   if(adx_main[1] < ADX_Min)
      return;

   int add = (adx_main[1] >= 25.0) ? 2 : 1;
   if(adx_plus[1] > adx_minus[1]) { buy_score += add; buy_reason += "ADX_DI_buy "; }
   if(adx_minus[1] > adx_plus[1]) { sell_score += add; sell_reason += "ADX_DI_sell "; }
}

//+------------------------------------------------------------------+
void ScoreMacd(double &macd_main[], double &macd_signal[],
               int &buy_score, int &sell_score,
               string &buy_reason, string &sell_reason)
{
   double h1 = macd_main[1] - macd_signal[1];
   double h2 = macd_main[2] - macd_signal[2];

   if(h1 > 0.0)
   {
      buy_score += (h1 > h2) ? 2 : 1;
      buy_reason += (h1 > h2) ? "MACD_up_strong " : "MACD_up ";
   }
   if(h1 < 0.0)
   {
      sell_score += (h1 < h2) ? 2 : 1;
      sell_reason += (h1 < h2) ? "MACD_down_strong " : "MACD_down ";
   }
}

//+------------------------------------------------------------------+
void ScoreRsi(double rsi_value,
              int &buy_score, int &sell_score,
              string &buy_reason, string &sell_reason)
{
   if(rsi_value >= 52.0 && rsi_value <= 68.0) { buy_score += 2; buy_reason += "RSI_buy_zone "; }
   else if(rsi_value > 68.0) buy_score--;

   if(rsi_value <= 48.0 && rsi_value >= 32.0) { sell_score += 2; sell_reason += "RSI_sell_zone "; }
   else if(rsi_value < 32.0) sell_score--;
}

//+------------------------------------------------------------------+
void ScoreStoch(double &stoch_k[], double &stoch_d[],
                int &buy_score, int &sell_score,
                string &buy_reason, string &sell_reason)
{
   if(stoch_k[1] > stoch_d[1] && stoch_k[1] < 85.0) { buy_score += 1; buy_reason += "Stoch_up "; }
   if(stoch_k[1] < stoch_d[1] && stoch_k[1] > 15.0) { sell_score += 1; sell_reason += "Stoch_down "; }
}

//+------------------------------------------------------------------+
void ScoreBandsAndVwap(double price, double bb_mid, double bb_up, double bb_low, double vwap,
                       int &buy_score, int &sell_score,
                       string &buy_reason, string &sell_reason)
{
   if(price > bb_mid && price < bb_up) { buy_score += 1; buy_reason += "BB_buy_side "; }
   if(price < bb_mid && price > bb_low) { sell_score += 1; sell_reason += "BB_sell_side "; }

   if(price > vwap) { buy_score += 1; buy_reason += "above_VWAP "; }
   if(price < vwap) { sell_score += 1; sell_reason += "below_VWAP "; }
}

//+------------------------------------------------------------------+
void ScoreMfi(double mfi_value,
              int &buy_score, int &sell_score,
              string &buy_reason, string &sell_reason)
{
   if(mfi_value > 50.0 && mfi_value < 80.0) { buy_score += 1; buy_reason += "MFI_buy_flow "; }
   if(mfi_value < 50.0 && mfi_value > 20.0) { sell_score += 1; sell_reason += "MFI_sell_flow "; }
}

//+------------------------------------------------------------------+
void ScoreTickImpulse(int &buy_score, int &sell_score,
                      string &buy_reason, string &sell_reason)
{
   if(tick_velocity > 0.25) { buy_score += 2; buy_reason += "tick_impulse_up "; }
   else if(tick_velocity > 0.05) { buy_score += 1; buy_reason += "tick_up "; }

   if(tick_velocity < -0.25) { sell_score += 2; sell_reason += "tick_impulse_down "; }
   else if(tick_velocity < -0.05) { sell_score += 1; sell_reason += "tick_down "; }
}

//+------------------------------------------------------------------+
void ExecuteSignal(SignalData &sig, double ask, double bid)
{
   int opened = 0;
   double lot = NormLot(BaseLot);

   for(int i = 0; i < sig.positions; i++)
   {
      ResetLastError();
      bool ok = false;
      if(sig.direction == 1)
         ok = trade.Buy(lot, _Symbol, ask, sig.sl, sig.tp, "M1 tick scalp buy");
      else
         ok = trade.Sell(lot, _Symbol, bid, sig.sl, sig.tp, "M1 tick scalp sell");

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
      last_trade_time = TimeCurrent();
      Print("OPEN ", opened, " ", DirStr(sig.direction),
            " score=", sig.score,
            " SL=", DoubleToString(sig.sl, _Digits),
            " TP=", DoubleToString(sig.tp, _Digits),
            " | ", sig.reason);
   }
}

//+------------------------------------------------------------------+
void ManagePositions()
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double max_loss_money = balance * MaxLossPctPerPosition / 100.0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!IsOurPosition(ticket))
         continue;

      double profit = PositionGetDouble(POSITION_PROFIT);
      if(profit >= ProfitTargetMoney)
      {
         if(trade.PositionClose(ticket))
            Print("Money target close ticket=", ticket, " profit=", DoubleToString(profit, 2));
         continue;
      }

      if(profit < 0.0 && MathAbs(profit) >= max_loss_money)
      {
         if(trade.PositionClose(ticket))
            Print("Risk close ticket=", ticket, " profit=", DoubleToString(profit, 2));
      }
   }
}

//+------------------------------------------------------------------+
void ApplyTrailing()
{
   if(!UseTrailing)
      return;

   double atr = GetCurrentATR();
   if(atr <= 0.0)
      return;

   double trail_start = MathMax(TrailStart_MinPips * PipSize, atr * TrailStart_ATR_Mult);
   double trail_step  = MathMax(TrailStep_MinPips * PipSize, atr * TrailStep_ATR_Mult);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!IsOurPosition(ticket))
         continue;

      long ptype = PositionGetInteger(POSITION_TYPE);
      double open_price = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl_cur = PositionGetDouble(POSITION_SL);
      double tp_cur = PositionGetDouble(POSITION_TP);
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      if(ptype == POSITION_TYPE_BUY)
      {
         double new_sl = NormalizeStopForBroker(1, bid - trail_step, ask, bid);
         new_sl = NormalizeDouble(new_sl, _Digits);
         if(bid - open_price >= trail_start && (sl_cur == 0.0 || new_sl > sl_cur + _Point))
            trade.PositionModify(ticket, new_sl, tp_cur);
      }
      else if(ptype == POSITION_TYPE_SELL)
      {
         double new_sl = NormalizeStopForBroker(-1, ask + trail_step, ask, bid);
         new_sl = NormalizeDouble(new_sl, _Digits);
         if(open_price - ask >= trail_start && (sl_cur == 0.0 || new_sl < sl_cur - _Point))
            trade.PositionModify(ticket, new_sl, tp_cur);
      }
   }
}

//+------------------------------------------------------------------+
double CalcSL(int direction, double atr_value, double ask, double bid)
{
   double dist = FixedSL_Pips * PipSize;
   if(UseATR_SL)
      dist = MathMax(atr_value * SL_ATR_Mult, FixedSL_Pips * PipSize * 0.5);

   double sl = (direction == 1) ? bid - dist : ask + dist;
   sl = NormalizeStopForBroker(direction, sl, ask, bid);
   return NormalizeDouble(sl, _Digits);
}

//+------------------------------------------------------------------+
double CalcTP(int direction, double atr_value, double ask, double bid)
{
   if(!UseDynamicTP)
      return 0.0;

   double spread = ask - bid;
   double dist = MathMax(atr_value * TP_ATR_Mult, spread * 1.20);
   double tp = (direction == 1) ? ask + dist : bid - dist;
   tp = NormalizeTakeProfitForBroker(direction, tp, ask, bid);
   return NormalizeDouble(tp, _Digits);
}

//+------------------------------------------------------------------+
double NormalizeStopForBroker(int direction, double sl, double ask, double bid)
{
   int stops_level = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double min_dist = MathMax(0, stops_level) * _Point;

   if(direction == 1)
      return MathMin(sl, bid - min_dist);
   return MathMax(sl, ask + min_dist);
}

//+------------------------------------------------------------------+
double NormalizeTakeProfitForBroker(int direction, double tp, double ask, double bid)
{
   int stops_level = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double min_dist = MathMax(0, stops_level) * _Point;

   if(direction == 1)
      return MathMax(tp, ask + min_dist);
   return MathMin(tp, bid - min_dist);
}

//+------------------------------------------------------------------+
void UpdateTickVelocity(double bid)
{
   datetime now = TimeCurrent();
   if(last_bid_seen <= 0.0 || last_tick_seen == 0)
   {
      last_bid_seen = bid;
      last_tick_seen = now;
      tick_velocity = 0.0;
      return;
   }

   int seconds = (int)MathMax(1, now - last_tick_seen);
   double move_pips = (bid - last_bid_seen) / PipSize;
   tick_velocity = move_pips / seconds;
   last_bid_seen = bid;
   last_tick_seen = now;
}

//+------------------------------------------------------------------+
double CalcRecentVWAP(int bars)
{
   int count = MathMax(2, bars);
   double pv = 0.0;
   double vol = 0.0;

   for(int i = 1; i <= count; i++)
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
double RecentRangePips(int bars)
{
   int count = MathMax(2, bars);
   int hi = iHighest(_Symbol, PERIOD_M1, MODE_HIGH, count, 1);
   int lo = iLowest(_Symbol, PERIOD_M1, MODE_LOW, count, 1);
   if(hi < 0 || lo < 0)
      return 0.0;

   return (iHigh(_Symbol, PERIOD_M1, hi) - iLow(_Symbol, PERIOD_M1, lo)) / PipSize;
}

//+------------------------------------------------------------------+
double GetCurrentATR()
{
   double atr[];
   if(!SafeCopy(h_atr, 0, atr, 3))
      return 0.0;
   return atr[1];
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
int CountOppositePositions(int direction)
{
   return CountPositionsByDirection(-direction);
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
