//+------------------------------------------------------------------+
//|              XAUUSD_Scalper_M1_Classic_v10_1.mq5                 |
//|  Strict M1 score-based GOLD scalper with fixed risk SL.           |
//+------------------------------------------------------------------+
#property copyright "2026 AndroindDeve + AI"
#property version   "10.1"
#property strict

#include <Trade\Trade.mqh>
CTrade trade;

//=== Inputs ==========================================================

input group "Version"
input string  EA_Version                 = "v10.1";

input group "Profit and risk"
input double  BaseLot                    = 0.01;
input double  MaxLotPerSignal            = 0.10;
input double  ProfitTargetMoney          = 1.5;    // Close each position at this profit
input double  RiskStopPctPerPosition     = 9.0;    // Initial SL and emergency close, % of balance per position
input bool    UseMoneyRiskSL             = true;   // Calculate SL from RiskStopPctPerPosition
input double  FallbackSL_Pips            = 35.0;   // Fallback if broker tick data is unavailable

input group "Signal sizing"
input int     WeakSignal_Positions       = 1;      // score 5-6
input int     MediumSignal_Positions     = 3;      // score 7-8
input int     StrongSignal_Positions     = 6;      // score 9+
input int     MinEntryScore              = 5;

input group "Smart pullback add"
input bool    UsePullbackAdds            = true;
input int     MaxPullbackAddsPerSide     = 3;
input double  PullbackDrawdownPct        = 0.5;    // Side drawdown, % balance, before add can happen
input double  PullbackMinPips            = 3.0;    // Price must move against side average by this much
input double  PullbackZonePips           = 2.0;    // Near EMA/BB/current candle low-high
input double  PullbackAtrPart            = 0.25;
input double  PullbackLotMult            = 1.2;
input int     PullbackMinScore           = 6;
input int     MinSecondsBetweenAdds      = 45;

input group "Execution filters"
input int     MaxTotalPositions          = 20;
input int     MaxPositionsPerSide        = 10;
input int     MinSecondsBetweenEntries   = 45;
input bool    OneEntryPerM1Bar           = true;
input bool    SignalOnlyOnNewM1Bar       = true;
input bool    CloseOppositeOnStrongSignal = true;
input int     OppositeCloseMinScore      = 8;
input bool    RequireDIDirection         = true;
input bool    AvoidChasingExtremes       = true;
input double  ExtremeBuffer_Pips         = 1.5;
input double  MaxChaseBodyAtrPart        = 0.45;
input double  SpreadAtrReduce_1          = 0.35;   // Spread/ATR reduces positions, never blocks
input double  SpreadAtrReduce_2          = 0.70;
input int     DeviationPoints            = 50;

input group "Session"
input int     GMT_Offset                 = 3;
input int     Session_Start_H            = 7;
input int     Session_End_H              = 21;

input group "Strict M1 indicators"
input int     EMA_Period                 = 20;
input int     EMA_Slope_Bars             = 3;
input double  MinEmaDistance_Pips        = 0.8;
input int     ADX_Period                 = 14;
input double  ADX_Min                    = 18.0;
input int     RSI_Period                 = 14;
input int     MACD_Fast                  = 12;
input int     MACD_Slow                  = 26;
input int     MACD_Signal                = 9;
input int     Stoch_K                    = 5;
input int     Stoch_D                    = 3;
input int     Stoch_Slowing              = 3;
input int     ATR_Period                 = 14;
input int     BB_Period                  = 20;
input double  BB_Dev                     = 2.0;
input int     MicroRange_Bars            = 5;
input double  MinMicroRange_Pips         = 3.0;

input group "Debug"
input bool    DebugMode                  = true;
input bool    DebugOpenPositions         = true;
input int     DebugPositionsEverySeconds = 30;

//=== Indicator handles ==============================================
int h_ema = INVALID_HANDLE;
int h_adx = INVALID_HANDLE;
int h_rsi = INVALID_HANDLE;
int h_macd = INVALID_HANDLE;
int h_stoch = INVALID_HANDLE;
int h_atr = INVALID_HANDLE;
int h_bb = INVALID_HANDLE;

//=== Globals =========================================================
long     MAGIC = 20261010;
double   PipSize = 0.0;
datetime last_signal_bar_time = 0;
datetime last_entry_time = 0;
datetime last_entry_bar_time = 0;
datetime last_pullback_buy_time = 0;
datetime last_pullback_sell_time = 0;
datetime last_positions_debug_time = 0;
int      pullback_levels_buy = 0;
int      pullback_levels_sell = 0;

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

   h_ema   = iMA(_Symbol, PERIOD_M1, EMA_Period, 0, MODE_EMA, PRICE_CLOSE);
   h_adx   = iADX(_Symbol, PERIOD_M1, ADX_Period);
   h_rsi   = iRSI(_Symbol, PERIOD_M1, RSI_Period, PRICE_CLOSE);
   h_macd  = iMACD(_Symbol, PERIOD_M1, MACD_Fast, MACD_Slow, MACD_Signal, PRICE_CLOSE);
   h_stoch = iStochastic(_Symbol, PERIOD_M1, Stoch_K, Stoch_D, Stoch_Slowing, MODE_SMA, STO_LOWHIGH);
   h_atr   = iATR(_Symbol, PERIOD_M1, ATR_Period);
   h_bb    = iBands(_Symbol, PERIOD_M1, BB_Period, 0, BB_Dev, PRICE_CLOSE);

   if(h_ema == INVALID_HANDLE || h_adx == INVALID_HANDLE || h_rsi == INVALID_HANDLE ||
      h_macd == INVALID_HANDLE || h_stoch == INVALID_HANDLE || h_atr == INVALID_HANDLE ||
      h_bb == INVALID_HANDLE)
   {
      Print("INIT_FAILED: all indicators must be available on PERIOD_M1");
      return INIT_FAILED;
   }

   trade.SetExpertMagicNumber(MAGIC);
   trade.SetDeviationInPoints(DeviationPoints);
   trade.SetAsyncMode(false);

   Print("XAUUSD Scalper M1 Classic ", EA_Version,
         " started. STRICT M1. Fixed ",
         DoubleToString(RiskStopPctPerPosition, 1), "% SL per position.");
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(h_ema);
   IndicatorRelease(h_adx);
   IndicatorRelease(h_rsi);
   IndicatorRelease(h_macd);
   IndicatorRelease(h_stoch);
   IndicatorRelease(h_atr);
   IndicatorRelease(h_bb);
}

//+------------------------------------------------------------------+
void OnTick()
{
   ManagePositions();
   PrintOpenPositionsDebug();

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0.0 || bid <= 0.0 || ask <= bid)
      return;

   if(UsePullbackAdds && IsTradingSession())
      CheckSmartPullbackAdds(ask, bid);

   if(!IsTradingSession())
      return;

   if(SignalOnlyOnNewM1Bar)
   {
      datetime bar_time = iTime(_Symbol, PERIOD_M1, 0);
      if(bar_time == last_signal_bar_time)
         return;
      last_signal_bar_time = bar_time;
   }

   if(CountOurPositions() >= MaxTotalPositions)
   {
      if(DebugMode)
         Print("SKIP max total positions: ", CountOurPositions(), "/", MaxTotalPositions);
      return;
   }

   if(!CanOpenNewEntry())
      return;

   SignalData sig = BuildSignal(ask, bid);
   if(DebugMode)
   {
      Print("SIGNAL ", DirStr(sig.direction),
            " score=", sig.score,
            " positions=", sig.positions,
            " SL=", DoubleToString(sig.sl_price, _Digits),
            " | ", sig.reason);
      PrintOpenPositionsDebug();
   }

   if(sig.direction != 0)
      ExecuteSignal(sig, ask, bid);
}

//+------------------------------------------------------------------+
SignalData EmptySignal(string reason)
{
   SignalData sig;
   sig.direction = 0;
   sig.score = 0;
   sig.positions = 0;
   sig.sl_price = 0.0;
   sig.reason = reason;
   return sig;
}

//+------------------------------------------------------------------+
SignalData BuildSignal(double ask, double bid)
{
   int ema_count = MathMax(EMA_Slope_Bars + 2, 5);
   double ema[], adx_main[], adx_plus[], adx_minus[];
   double rsi[], macd_main[], macd_signal[];
   double stoch_k[], stoch_d[];
   double atr[], bb_up[], bb_mid[], bb_low[];

   if(!SafeCopy(h_ema,   0, ema,         ema_count)) return EmptySignal("EMA data missing");
   if(!SafeCopy(h_adx,   0, adx_main,    4))         return EmptySignal("ADX data missing");
   if(!SafeCopy(h_adx,   1, adx_plus,    4))         return EmptySignal("DI+ data missing");
   if(!SafeCopy(h_adx,   2, adx_minus,   4))         return EmptySignal("DI- data missing");
   if(!SafeCopy(h_rsi,   0, rsi,         4))         return EmptySignal("RSI data missing");
   if(!SafeCopy(h_macd,  0, macd_main,   4))         return EmptySignal("MACD main data missing");
   if(!SafeCopy(h_macd,  1, macd_signal, 4))         return EmptySignal("MACD signal data missing");
   if(!SafeCopy(h_stoch, 0, stoch_k,     4))         return EmptySignal("Stochastic K data missing");
   if(!SafeCopy(h_stoch, 1, stoch_d,     4))         return EmptySignal("Stochastic D data missing");
   if(!SafeCopy(h_atr,   0, atr,         4))         return EmptySignal("ATR data missing");
   if(!SafeCopy(h_bb,    0, bb_up,       4))         return EmptySignal("BB upper data missing");
   if(!SafeCopy(h_bb,    1, bb_mid,      4))         return EmptySignal("BB middle data missing");
   if(!SafeCopy(h_bb,    2, bb_low,      4))         return EmptySignal("BB lower data missing");

   double price = (ask + bid) * 0.5;
   double dist_pips = (price - ema[0]) / PipSize;
   double atr_pips = (atr[1] > 0.0) ? atr[1] / PipSize : 0.0;

   if(adx_main[1] < ADX_Min)
      return EmptySignal("flat ADX=" + DoubleToString(adx_main[1], 1));

   int direction = 0;
   if(dist_pips >= MinEmaDistance_Pips)
      direction = 1;
   else if(dist_pips <= -MinEmaDistance_Pips)
      direction = -1;
   else
      return EmptySignal("too close to EMA20 dist=" + DoubleToString(dist_pips, 1));

   if(CountPositionsByDirection(direction) >= MaxPositionsPerSide)
      return EmptySignal("side position limit reached");

   int score = ScoreDirection(direction, ema, adx_main, adx_plus, adx_minus,
                              rsi, macd_main, macd_signal, stoch_k, stoch_d,
                              bb_up, bb_mid, bb_low);
   string reason = LastScoreReason(direction, price, ema[0], dist_pips, adx_main[1]);

   if(AvoidChasingExtremes && IsEntryOverextended(direction, price, atr[1], bb_up[0], bb_low[0]))
      return EmptySignal(reason + " avoid chasing current M1 extreme");

   double micro_range = RecentRangePips(MicroRange_Bars);
   if(micro_range < MinMicroRange_Pips)
      return EmptySignal(reason + " dead micro range=" + DoubleToString(micro_range, 1));

   if(score < MinEntryScore)
      return EmptySignal(reason + " score too low=" + IntegerToString(score));

   int positions = PositionsForScore(score);
   int lot_cap = (int)MathFloor(MaxLotPerSignal / BaseLot);
   positions = MathMax(1, MathMin(positions, lot_cap));
   positions = MathMin(positions, MaxPositionsPerSide - CountPositionsByDirection(direction));
   positions = MathMin(positions, MaxTotalPositions - CountOurPositions());

   double spread_atr_ratio = (atr[1] > 0.0) ? ((ask - bid) / atr[1]) : 0.0;
   if(spread_atr_ratio >= SpreadAtrReduce_2)
      positions = MathMax(1, positions - 2);
   else if(spread_atr_ratio >= SpreadAtrReduce_1)
      positions = MathMax(1, positions - 1);

   if(positions <= 0)
      return EmptySignal(reason + " no capacity");

   SignalData sig;
   sig.direction = direction;
   sig.score = score;
   sig.positions = positions;
   sig.sl_price = CalcRiskSL(direction, ask, bid, BaseLot, atr[1]);
   sig.reason = reason +
                " score=" + IntegerToString(score) +
                " microRange=" + DoubleToString(micro_range, 1) +
                " spread=" + DoubleToString((ask - bid) / PipSize, 1) +
                "p spreadATR=" + DoubleToString(spread_atr_ratio, 2);
   return sig;
}

//+------------------------------------------------------------------+
int ScoreDirection(int direction,
                   double &ema[], double &adx_main[], double &adx_plus[], double &adx_minus[],
                   double &rsi[], double &macd_main[], double &macd_signal[],
                   double &stoch_k[], double &stoch_d[],
                   double &bb_up[], double &bb_mid[], double &bb_low[])
{
   int score = 0;
   double slope = (ema[0] - ema[EMA_Slope_Bars]) / PipSize;
   bool di_ok = (direction == 1) ? (adx_plus[1] > adx_minus[1])
                                 : (adx_minus[1] > adx_plus[1]);

   if(RequireDIDirection && !di_ok)
      return -99;

   if(direction == 1)
   {
      if(slope > 2.0) score += 3;
      else if(slope > 0.5) score += 2;
      else if(slope >= 0.0) score += 1;
      else score -= 2;

      if(di_ok) score += (adx_main[1] > 30.0 ? 2 : 1);

      double macd_hist_1 = macd_main[1] - macd_signal[1];
      double macd_hist_2 = macd_main[2] - macd_signal[2];
      if(macd_hist_1 > 0.0 && macd_hist_1 > macd_hist_2) score += 2;
      else if(macd_hist_1 > 0.0) score += 1;
      else score -= 1;

      if(rsi[1] > 55.0 && rsi[1] < 70.0) score += 3;
      else if(rsi[1] >= 50.0 && rsi[1] <= 55.0) score += 2;
      else if(rsi[1] >= 40.0 && rsi[1] < 50.0) score += 1;
      else if(rsi[1] >= 70.0) score -= 2;

      if(stoch_k[1] < 80.0 && stoch_k[1] > stoch_d[1]) score += 2;
      else if(stoch_k[1] < 80.0) score += 1;
      else score -= 1;

      double close_m1 = iClose(_Symbol, PERIOD_M1, 1);
      if(close_m1 > bb_mid[1] && close_m1 < bb_up[1]) score += 1;
   }
   else
   {
      if(slope < -2.0) score += 3;
      else if(slope < -0.5) score += 2;
      else if(slope <= 0.0) score += 1;
      else score -= 2;

      if(di_ok) score += (adx_main[1] > 30.0 ? 2 : 1);

      double macd_hist_1 = macd_main[1] - macd_signal[1];
      double macd_hist_2 = macd_main[2] - macd_signal[2];
      if(macd_hist_1 < 0.0 && macd_hist_1 < macd_hist_2) score += 2;
      else if(macd_hist_1 < 0.0) score += 1;
      else score -= 1;

      if(rsi[1] < 45.0 && rsi[1] > 30.0) score += 3;
      else if(rsi[1] >= 45.0 && rsi[1] <= 50.0) score += 2;
      else if(rsi[1] > 50.0 && rsi[1] <= 60.0) score += 1;
      else if(rsi[1] <= 30.0) score -= 2;

      if(stoch_k[1] > 20.0 && stoch_k[1] < stoch_d[1]) score += 2;
      else if(stoch_k[1] > 20.0) score += 1;
      else score -= 1;

      double close_m1 = iClose(_Symbol, PERIOD_M1, 1);
      if(close_m1 < bb_mid[1] && close_m1 > bb_low[1]) score += 1;
   }

   return MathMin(score, 12);
}

//+------------------------------------------------------------------+
string LastScoreReason(int direction, double price, double ema_now, double dist_pips, double adx)
{
   string side = (direction == 1) ? "EMA20_M1_BUY " : "EMA20_M1_SELL ";
   return side +
          "price=" + DoubleToString(price, _Digits) +
          " ema=" + DoubleToString(ema_now, _Digits) +
          " dist=" + DoubleToString(dist_pips, 1) +
          "p ADX=" + DoubleToString(adx, 1) + " ";
}

//+------------------------------------------------------------------+
int PositionsForScore(int score)
{
   if(score >= 9)
      return StrongSignal_Positions;
   if(score >= 7)
      return MediumSignal_Positions;
   return WeakSignal_Positions;
}

//+------------------------------------------------------------------+
void ExecuteSignal(SignalData &sig, double ask, double bid)
{
   if(CloseOppositeOnStrongSignal && sig.score >= OppositeCloseMinScore)
      CloseOppositePositions(sig.direction);

   double lot = NormLot(BaseLot);
   int opened = 0;

   for(int i = 0; i < sig.positions; i++)
   {
      ResetLastError();
      bool ok = false;
      if(sig.direction == 1)
         ok = trade.Buy(lot, _Symbol, ask, sig.sl_price, 0.0, "M1 v10.1 buy");
      else
         ok = trade.Sell(lot, _Symbol, bid, sig.sl_price, 0.0, "M1 v10.1 sell");

      if(ok)
         opened++;
      else
      {
         Print("ORDER_FAIL ", DirStr(sig.direction),
               " retcode=", trade.ResultRetcode(),
               " desc=", trade.ResultRetcodeDescription(),
               " last_error=", GetLastError());
         break;
      }
   }

   if(opened > 0)
   {
      last_entry_time = TimeCurrent();
      last_entry_bar_time = iTime(_Symbol, PERIOD_M1, 0);
      if(sig.direction == 1)
         pullback_levels_buy = 0;
      else
         pullback_levels_sell = 0;

      Print("OPEN_SIGNAL ", DirStr(sig.direction),
            " opened=", opened,
            " requested=", sig.positions,
            " lot=", DoubleToString(lot, 2),
            " score=", sig.score,
            " SL=", DoubleToString(sig.sl_price, _Digits),
            " reason=", sig.reason);
   }
}

//+------------------------------------------------------------------+
void ManagePositions()
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double max_loss = balance * RiskStopPctPerPosition / 100.0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!IsOurPosition(ticket))
         continue;

      double profit = PositionGetDouble(POSITION_PROFIT);
      if(profit >= ProfitTargetMoney)
      {
         if(trade.PositionClose(ticket))
            Print("PROFIT_CLOSE ticket=", ticket, " profit=", DoubleToString(profit, 2));
         continue;
      }

      if(profit < 0.0 && MathAbs(profit) >= max_loss)
      {
         if(trade.PositionClose(ticket))
            Print("EMERGENCY_9PCT_CLOSE ticket=", ticket,
                  " profit=", DoubleToString(profit, 2),
                  " limit=", DoubleToString(max_loss, 2));
      }
   }
}

//+------------------------------------------------------------------+
void CheckSmartPullbackAdds(double ask, double bid)
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double threshold = balance * PullbackDrawdownPct / 100.0;
   if(threshold <= 0.0)
      return;

   TryPullbackAdd(1, ask, bid, threshold);
   TryPullbackAdd(-1, ask, bid, threshold);
}

//+------------------------------------------------------------------+
void TryPullbackAdd(int direction, double ask, double bid, double threshold)
{
   int side_count = CountPositionsByDirection(direction);
   if(side_count <= 0 || side_count >= MaxPositionsPerSide)
      return;

   int levels = (direction == 1) ? pullback_levels_buy : pullback_levels_sell;
   datetime last_add_time = (direction == 1) ? last_pullback_buy_time : last_pullback_sell_time;
   if(levels >= MaxPullbackAddsPerSide)
      return;
   if(TimeCurrent() - last_add_time < MinSecondsBetweenAdds)
      return;

   double side_profit = SideProfit(direction);
   if(side_profit >= 0.0 || MathAbs(side_profit) < threshold)
      return;

   double avg_price = SideAverageOpenPrice(direction);
   if(avg_price <= 0.0)
      return;

   double adverse_pips = (direction == 1) ? (avg_price - bid) / PipSize
                                          : (ask - avg_price) / PipSize;
   if(adverse_pips < PullbackMinPips)
      return;

   if(!IsM1DirectionStillValid(direction))
      return;
   if(!IsPullbackZone(direction, ask, bid))
      return;

   double lot = NormLot(BaseLot * MathPow(PullbackLotMult, levels));
   double atr[];
   if(!SafeCopy(h_atr, 0, atr, 3))
      return;

   double sl = CalcRiskSL(direction, ask, bid, lot, atr[1]);
   ResetLastError();
   bool ok = (direction == 1)
             ? trade.Buy(lot, _Symbol, ask, sl, 0.0, "M1 v10.1 pullback buy")
             : trade.Sell(lot, _Symbol, bid, sl, 0.0, "M1 v10.1 pullback sell");

   if(ok)
   {
      if(direction == 1)
      {
         pullback_levels_buy++;
         last_pullback_buy_time = TimeCurrent();
      }
      else
      {
         pullback_levels_sell++;
         last_pullback_sell_time = TimeCurrent();
      }

      last_entry_time = TimeCurrent();
      last_entry_bar_time = iTime(_Symbol, PERIOD_M1, 0);
      Print("PULLBACK_ADD ", DirStr(direction),
            " level=", levels + 1,
            " lot=", DoubleToString(lot, 2),
            " sidePnL=", DoubleToString(side_profit, 2),
            " adverse=", DoubleToString(adverse_pips, 1),
            " SL=", DoubleToString(sl, _Digits));
   }
   else
   {
      Print("PULLBACK_FAIL ", DirStr(direction),
            " retcode=", trade.ResultRetcode(),
            " desc=", trade.ResultRetcodeDescription(),
            " last_error=", GetLastError());
   }
}

//+------------------------------------------------------------------+
bool IsM1DirectionStillValid(int direction)
{
   double ema[], adx_main[], adx_plus[], adx_minus[];
   double rsi[], macd_main[], macd_signal[], stoch_k[], stoch_d[];
   int ema_count = MathMax(EMA_Slope_Bars + 2, 5);

   if(!SafeCopy(h_ema,   0, ema,         ema_count)) return false;
   if(!SafeCopy(h_adx,   0, adx_main,    4))         return false;
   if(!SafeCopy(h_adx,   1, adx_plus,    4))         return false;
   if(!SafeCopy(h_adx,   2, adx_minus,   4))         return false;
   if(!SafeCopy(h_rsi,   0, rsi,         4))         return false;
   if(!SafeCopy(h_macd,  0, macd_main,   4))         return false;
   if(!SafeCopy(h_macd,  1, macd_signal, 4))         return false;
   if(!SafeCopy(h_stoch, 0, stoch_k,     4))         return false;
   if(!SafeCopy(h_stoch, 1, stoch_d,     4))         return false;

   if(adx_main[1] < ADX_Min)
      return false;

   double price = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) +
                   SymbolInfoDouble(_Symbol, SYMBOL_BID)) * 0.5;
   double slope = (ema[0] - ema[EMA_Slope_Bars]) / PipSize;
   double macd_hist = macd_main[1] - macd_signal[1];

   if(direction == 1)
   {
      if(price < ema[0] && slope < 0.0) return false;
      if(RequireDIDirection && adx_plus[1] <= adx_minus[1]) return false;
      if(macd_hist < 0.0 && rsi[1] < 50.0) return false;
      if(stoch_k[1] < stoch_d[1] && rsi[1] < 48.0) return false;
      return true;
   }

   if(price > ema[0] && slope > 0.0) return false;
   if(RequireDIDirection && adx_minus[1] <= adx_plus[1]) return false;
   if(macd_hist > 0.0 && rsi[1] > 50.0) return false;
   if(stoch_k[1] > stoch_d[1] && rsi[1] > 52.0) return false;
   return true;
}

//+------------------------------------------------------------------+
bool IsPullbackZone(int direction, double ask, double bid)
{
   double ema[], bb_up[], bb_mid[], bb_low[], atr[];
   if(!SafeCopy(h_ema, 0, ema,    3)) return false;
   if(!SafeCopy(h_bb,  0, bb_up,  3)) return false;
   if(!SafeCopy(h_bb,  1, bb_mid, 3)) return false;
   if(!SafeCopy(h_bb,  2, bb_low, 3)) return false;
   if(!SafeCopy(h_atr, 0, atr,    3)) return false;

   double price = (ask + bid) * 0.5;
   double atr_pips = atr[1] / PipSize;
   double max_dist = MathMax(PullbackZonePips, atr_pips * PullbackAtrPart);

   double open0 = iOpen(_Symbol, PERIOD_M1, 0);
   double high0 = iHigh(_Symbol, PERIOD_M1, 0);
   double low0 = iLow(_Symbol, PERIOD_M1, 0);
   double close0 = iClose(_Symbol, PERIOD_M1, 0);
   if(open0 <= 0.0 || high0 <= 0.0 || low0 <= 0.0 || close0 <= 0.0)
      return false;

   if(direction == 1)
   {
      bool bearish_pullback = close0 < open0;
      bool near_support = (MathAbs(price - ema[0]) / PipSize <= max_dist) ||
                          (MathAbs(price - bb_mid[0]) / PipSize <= max_dist) ||
                          ((price - low0) / PipSize <= ExtremeBuffer_Pips);
      bool not_chasing_high = ((high0 - price) / PipSize > ExtremeBuffer_Pips);
      return bearish_pullback && near_support && not_chasing_high;
   }

   bool bullish_pullback = close0 > open0;
   bool near_resistance = (MathAbs(price - ema[0]) / PipSize <= max_dist) ||
                          (MathAbs(price - bb_mid[0]) / PipSize <= max_dist) ||
                          ((high0 - price) / PipSize <= ExtremeBuffer_Pips);
   bool not_chasing_low = ((price - low0) / PipSize > ExtremeBuffer_Pips);
   return bullish_pullback && near_resistance && not_chasing_low;
}

//+------------------------------------------------------------------+
bool IsEntryOverextended(int direction, double price, double atr_value,
                         double bb_up, double bb_low)
{
   if(!AvoidChasingExtremes)
      return false;

   double open0 = iOpen(_Symbol, PERIOD_M1, 0);
   double high0 = iHigh(_Symbol, PERIOD_M1, 0);
   double low0 = iLow(_Symbol, PERIOD_M1, 0);
   double close0 = iClose(_Symbol, PERIOD_M1, 0);
   if(open0 <= 0.0 || high0 <= 0.0 || low0 <= 0.0 || close0 <= 0.0)
      return false;

   double body_pips = MathAbs(close0 - open0) / PipSize;
   double atr_pips = (atr_value > 0.0) ? atr_value / PipSize : 0.0;
   double max_body = MathMax(ExtremeBuffer_Pips, atr_pips * MaxChaseBodyAtrPart);
   if(body_pips < max_body)
      return false;

   if(direction == 1)
   {
      bool near_high = ((high0 - price) / PipSize <= ExtremeBuffer_Pips);
      bool near_upper_band = (bb_up > 0.0 && price >= bb_up - ExtremeBuffer_Pips * PipSize);
      return near_high || near_upper_band;
   }

   bool near_low = ((price - low0) / PipSize <= ExtremeBuffer_Pips);
   bool near_lower_band = (bb_low > 0.0 && price <= bb_low + ExtremeBuffer_Pips * PipSize);
   return near_low || near_lower_band;
}

//+------------------------------------------------------------------+
double CalcRiskSL(int direction, double ask, double bid, double lot, double atr_val)
{
   double sl_dist = FallbackSL_Pips * PipSize;

   if(UseMoneyRiskSL)
   {
      double risk_money = AccountInfoDouble(ACCOUNT_BALANCE) * RiskStopPctPerPosition / 100.0;
      double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
      double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

      if(risk_money > 0.0 && tick_value > 0.0 && tick_size > 0.0 && lot > 0.0)
         sl_dist = (risk_money / (tick_value * lot)) * tick_size;
      else if(atr_val > 0.0)
         sl_dist = MathMax(atr_val * 1.5, FallbackSL_Pips * PipSize);
   }
   else if(atr_val > 0.0)
   {
      sl_dist = MathMax(atr_val * 1.5, FallbackSL_Pips * PipSize);
   }

   double sl = (direction == 1) ? bid - sl_dist : ask + sl_dist;
   sl = NormalizeInitialStop(direction, sl, ask, bid);
   return NormalizeDouble(sl, _Digits);
}

//+------------------------------------------------------------------+
double NormalizeInitialStop(int direction, double sl, double ask, double bid)
{
   int stops_level = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   int freeze_level = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   int min_points = MathMax(stops_level, freeze_level) + 2;
   double min_dist = MathMax(min_points * _Point, _Point);

   if(direction == 1)
      return MathMin(sl, bid - min_dist);
   return MathMax(sl, ask + min_dist);
}

//+------------------------------------------------------------------+
bool CanOpenNewEntry()
{
   if(TimeCurrent() - last_entry_time < MinSecondsBetweenEntries)
      return false;

   if(OneEntryPerM1Bar)
   {
      datetime bar_time = iTime(_Symbol, PERIOD_M1, 0);
      if(bar_time == last_entry_bar_time)
         return false;
   }

   return true;
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
         Print("COPY_FAIL handle=", handle, " buffer=", buffer, " copied=", copied);
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
int CountPositionsByDirection(int direction)
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
void CloseOppositePositions(int direction)
{
   long opposite = (direction == 1) ? POSITION_TYPE_SELL : POSITION_TYPE_BUY;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!IsOurPosition(ticket))
         continue;
      if(PositionGetInteger(POSITION_TYPE) != opposite)
         continue;

      double profit = PositionGetDouble(POSITION_PROFIT);
      if(trade.PositionClose(ticket))
         Print("CLOSE_OPPOSITE ticket=", ticket, " profit=", DoubleToString(profit, 2));
   }
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
double SideProfit(int direction)
{
   double profit = 0.0;
   long wanted = (direction == 1) ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!IsOurPosition(ticket))
         continue;
      if(PositionGetInteger(POSITION_TYPE) == wanted)
         profit += PositionGetDouble(POSITION_PROFIT);
   }
   return profit;
}

//+------------------------------------------------------------------+
double SideAverageOpenPrice(int direction)
{
   double weighted_sum = 0.0;
   double volume_sum = 0.0;
   long wanted = (direction == 1) ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!IsOurPosition(ticket))
         continue;
      if(PositionGetInteger(POSITION_TYPE) != wanted)
         continue;

      double volume = PositionGetDouble(POSITION_VOLUME);
      weighted_sum += PositionGetDouble(POSITION_PRICE_OPEN) * volume;
      volume_sum += volume;
   }

   if(volume_sum <= 0.0)
      return 0.0;
   return weighted_sum / volume_sum;
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
void PrintOpenPositionsDebug()
{
   if(!DebugOpenPositions)
      return;

   datetime now = TimeCurrent();
   if(now - last_positions_debug_time < DebugPositionsEverySeconds)
      return;
   last_positions_debug_time = now;

   int buy_count = CountPositionsByDirection(1);
   int sell_count = CountPositionsByDirection(-1);
   double buy_avg = SideAverageOpenPrice(1);
   double sell_avg = SideAverageOpenPrice(-1);

   Print("POSITIONS ", EA_Version,
         " | BUY count=", buy_count,
         " avg=", DoubleToString(buy_avg, _Digits),
         " PnL=", DoubleToString(SideProfit(1), 2),
         " pullbacks=", pullback_levels_buy,
         " || SELL count=", sell_count,
         " avg=", DoubleToString(sell_avg, _Digits),
         " PnL=", DoubleToString(SideProfit(-1), 2),
         " pullbacks=", pullback_levels_sell);
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
