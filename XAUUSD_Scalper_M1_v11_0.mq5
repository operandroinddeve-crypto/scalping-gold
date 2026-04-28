//+------------------------------------------------------------------+
//|              XAUUSD_Scalper_M1_v11_0.mq5                         |
//|  M1 GOLD scalper v11.3                                           |
//|                                                                   |
//|  Fixed vs v11.2:                                                 |
//|  [BUG] UseH1Filter=true blocked every entry (H1 rarely aligned  |
//|         with M1 scalp direction) – now false by default          |
//|  [BUG] Auto lot-sizing produced 0.23 lot instead of 0.01        |
//|  [FIX] Fixed BaseLot=0.01 – no auto-sizing, user controls size  |
//|  [FIX] MaxTotalPositions=15, MaxPositionsPerSide=10 for scaling  |
//|  [FIX] BlockNewEntryWhenInMarket=false – scales into moves       |
//|  [FIX] Pyramid adds use same BaseLot (not half)                  |
//+------------------------------------------------------------------+
#property copyright "2026 AndroindDeve + AI"
#property version   "11.3"
#property strict

#include <Trade\Trade.mqh>
CTrade trade;

//=== Inputs ==========================================================

input group "Version"
input string  EA_Version = "v11.3";

input group "Risk Management"
input double  BaseLot            = 0.01;  // Fixed lot size per position (no auto-sizing)
// SL/TP are ATR-based – auto-adapt to XAUUSD volatility (ATR M1 ~150-300 pips)
input double  SL_ATR_Mult        = 1.5;   // SL = ATR * this (floor = MinSL_Pips and spread*2)
input double  TP_ATR_Mult        = 2.0;   // TP = ATR * this  → R:R = 1.33:1
input double  MinSL_Pips         = 50.0;  // Absolute minimum SL (pips)
// Breakeven and trailing use ATR fractions
input double  BreakevenAt_ATR    = 0.6;   // Move SL to breakeven when profit >= ATR*this
input double  TrailActivate_ATR  = 0.9;   // Activate trailing when profit >= ATR*this
input double  TrailStep_ATR      = 0.4;   // Trailing distance = ATR * this

input group "Signal sizing"
input int     WeakSignal_Positions   = 1; // score  8-9  → 1 position
input int     MediumSignal_Positions = 2; // score 10-11 → 2 positions
input int     StrongSignal_Positions = 3; // score  12   → 3 positions
input int     MinEntryScore          = 8;

input group "Execution filters"
input int     MaxTotalPositions           = 15;   // Allow up to 15 open positions
input int     MaxPositionsPerSide         = 10;   // Up to 10 per direction
input int     MinSecondsBetweenEntries    = 30;   // Faster re-entry on M1
input bool    BlockNewEntryWhenInMarket   = false; // false = scale into moves
input bool    OneEntryPerM1Bar            = true;
input bool    SignalOnlyOnNewM1Bar        = true;
input bool    AllowHedging                = false; // false = no simultaneous BUY+SELL positions
input bool    CloseOppositeOnStrongSignal = true;  // Close opposite positions on strong signal
input int     OppositeCloseMinScore       = 11;
input bool    RequireDIDirection          = true;
input bool    AvoidChasingExtremes        = true;
input double  ExtremeBuffer_Pips          = 1.5;
input double  MaxChaseBodyAtrPart         = 0.45;
input double  SpreadAtrReduce_1           = 0.30;  // Spread/ATR ratio: reduce 1 position
input double  SpreadAtrReduce_2           = 0.55;  // Spread/ATR ratio: reduce 2 positions
input int     DeviationPoints             = 30;
input bool    ManageLegacyMagic           = true;
// XAUUSD spreads are 15-50 pips during normal hours, 0 = disabled
input double  MaxSpreadPips               = 50.0;  // Skip entry if spread > this (0 = no limit)

input group "Pyramid adds (profitable side only)"
input bool    UsePyramidAdds        = true;
input int     MaxPyramidAddsPerSide = 1;
input double  PyramidMinProfitPips  = 12.0; // Min avg profit (pips) before pyramid add
input double  PyramidZonePips       = 2.0;  // Near EMA/BB zone width for pyramid
input double  PyramidAtrPart        = 0.20;
input int     PullbackMinScore      = 8;
input int     MinSecondsBetweenAdds = 90;

input group "Session (hours in GMT)"
input int     GMT_Offset      = 3;  // Broker server time offset from GMT (e.g. 3 = UTC+3)
input int     Session_Start_H = 7;  // Session open hour (GMT)
input int     Session_End_H   = 21; // Session close hour (GMT)

input group "M1 Indicators"
input int     EMA_Period          = 9;    // Fast EMA – direction + slope (was 20)
input int     EMA_Slope_Bars      = 3;
input double  MinEmaDistance_Pips = 0.5;  // Min pips from EMA to open direction
input int     ADX_Period          = 14;
input double  ADX_Min             = 20.0;
input int     RSI_Period          = 9;    // Fast RSI for M1 (was 14)
input int     MACD_Fast           = 3;    // Fast MACD for M1 (was 12)
input int     MACD_Slow           = 10;   // (was 26)
input int     MACD_Signal_P       = 3;    // (was 9)
input int     Stoch_K             = 5;
input int     Stoch_D             = 3;
input int     Stoch_Slowing       = 3;
input int     ATR_Period          = 14;
input int     BB_Period           = 20;
input double  BB_Dev              = 2.0;
input int     MicroRange_Bars     = 5;
input double  MinMicroRange_Pips  = 2.0;

input group "H1 Trend Filter"
input bool    UseH1Filter    = false; // false = pure M1 scalping; true = require H1 EMA align
input int     H1_EMA_Period  = 50;    // H1 EMA period used when UseH1Filter=true

input group "Debug"
input bool    DebugMode                  = true;
input bool    DebugOpenPositions         = true;
input int     DebugPositionsEverySeconds = 30;

//=== Indicator handles ==============================================
int h_ema   = INVALID_HANDLE;
int h_adx   = INVALID_HANDLE;
int h_rsi   = INVALID_HANDLE;
int h_macd  = INVALID_HANDLE;
int h_stoch = INVALID_HANDLE;
int h_atr   = INVALID_HANDLE;
int h_bb    = INVALID_HANDLE;
int h_h1ema = INVALID_HANDLE;

//=== Globals =========================================================
long     MAGIC = 20261010;
double   PipSize = 0.0;
datetime last_signal_bar_time    = 0;
datetime last_entry_time         = 0;
datetime last_entry_bar_time     = 0;
datetime last_pyramid_buy_time   = 0;
datetime last_pyramid_sell_time  = 0;
datetime last_positions_debug_time = 0;
int      pyramid_levels_buy  = 0;
int      pyramid_levels_sell = 0;

struct SignalData
{
   int    direction;
   int    score;
   int    positions;
   double sl_price;
   double tp_price;
   double lot;
   string reason;
};

//+------------------------------------------------------------------+
int OnInit()
{
   PipSize = CalcPipSize();

   h_ema   = iMA(_Symbol, PERIOD_M1, EMA_Period, 0, MODE_EMA, PRICE_CLOSE);
   h_adx   = iADX(_Symbol, PERIOD_M1, ADX_Period);
   h_rsi   = iRSI(_Symbol, PERIOD_M1, RSI_Period, PRICE_CLOSE);
   h_macd  = iMACD(_Symbol, PERIOD_M1, MACD_Fast, MACD_Slow, MACD_Signal_P, PRICE_CLOSE);
   h_stoch = iStochastic(_Symbol, PERIOD_M1, Stoch_K, Stoch_D, Stoch_Slowing, MODE_SMA, STO_LOWHIGH);
   h_atr   = iATR(_Symbol, PERIOD_M1, ATR_Period);
   h_bb    = iBands(_Symbol, PERIOD_M1, BB_Period, 0, BB_Dev, PRICE_CLOSE);
   h_h1ema = iMA(_Symbol, PERIOD_H1, H1_EMA_Period, 0, MODE_EMA, PRICE_CLOSE);

   if(h_ema == INVALID_HANDLE || h_adx == INVALID_HANDLE || h_rsi == INVALID_HANDLE ||
      h_macd == INVALID_HANDLE || h_stoch == INVALID_HANDLE || h_atr == INVALID_HANDLE ||
      h_bb == INVALID_HANDLE || h_h1ema == INVALID_HANDLE)
   {
      Print("INIT_FAILED: indicator handles could not be created");
      return INIT_FAILED;
   }

   trade.SetExpertMagicNumber(MAGIC);
   trade.SetDeviationInPoints(DeviationPoints);
   trade.SetAsyncMode(false);

   Print("XAUUSD Scalper M1 ", EA_Version, " started.",
         " Lot=", BaseLot,
         " SL=", SL_ATR_Mult, "xATR TP=", TP_ATR_Mult, "xATR",
         " MinSL=", MinSL_Pips, "p",
         " MaxPos=", MaxTotalPositions, "/", MaxPositionsPerSide,
         " H1Filter=", UseH1Filter,
         " MaxSpread=", MaxSpreadPips, "p");
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
   IndicatorRelease(h_h1ema);
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

   if(UsePyramidAdds && IsTradingSession())
      CheckSmartPyramidAdds(ask, bid);

   if(!IsTradingSession())
      return;

   if(SignalOnlyOnNewM1Bar)
   {
      datetime bar_time = iTime(_Symbol, PERIOD_M1, 0);
      if(bar_time == last_signal_bar_time)
         return;
      last_signal_bar_time = bar_time;
   }

   // [FIX] BlockNewEntryWhenInMarket is now actually checked (was hardcoded before)
   if(BlockNewEntryWhenInMarket && CountOurPositions() > 0)
   {
      if(DebugMode)
         Print("SKIP: BlockNewEntryWhenInMarket=true, positions=", CountOurPositions());
      return;
   }

   if(CountOurPositions() >= MaxTotalPositions)
   {
      if(DebugMode)
         Print("SKIP: max total positions ", CountOurPositions(), "/", MaxTotalPositions);
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
            " lot=", DoubleToString(sig.lot, 2),
            " SL=", DoubleToString(sig.sl_price, _Digits),
            " TP=", DoubleToString(sig.tp_price, _Digits),
            " | ", sig.reason);
   }

   if(sig.direction != 0)
      ExecuteSignal(sig, ask, bid);
}

//+------------------------------------------------------------------+
SignalData EmptySignal(string reason)
{
   SignalData sig;
   sig.direction = 0;
   sig.score     = 0;
   sig.positions = 0;
   sig.sl_price  = 0.0;
   sig.tp_price  = 0.0;
   sig.lot       = 0.0;
   sig.reason    = reason;
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
   if(!SafeCopy(h_macd,  0, macd_main,   4))         return EmptySignal("MACD main missing");
   if(!SafeCopy(h_macd,  1, macd_signal, 4))         return EmptySignal("MACD signal missing");
   if(!SafeCopy(h_stoch, 0, stoch_k,     4))         return EmptySignal("Stoch K missing");
   if(!SafeCopy(h_stoch, 1, stoch_d,     4))         return EmptySignal("Stoch D missing");
   if(!SafeCopy(h_atr,   0, atr,         4))         return EmptySignal("ATR data missing");
   if(!SafeCopy(h_bb,    0, bb_up,       4))         return EmptySignal("BB upper missing");
   if(!SafeCopy(h_bb,    1, bb_mid,      4))         return EmptySignal("BB middle missing");
   if(!SafeCopy(h_bb,    2, bb_low,      4))         return EmptySignal("BB lower missing");

   // Hard spread filter
   double spread_pips = (ask - bid) / PipSize;
   if(MaxSpreadPips > 0.0 && spread_pips > MaxSpreadPips)
      return EmptySignal("spread too high=" + DoubleToString(spread_pips, 1) + "p");

   double price = (ask + bid) * 0.5;
   double dist_pips = (price - ema[0]) / PipSize;
   double atr_pips  = (atr[1] > 0.0) ? atr[1] / PipSize : 0.0;

   if(adx_main[1] < ADX_Min)
      return EmptySignal("flat ADX=" + DoubleToString(adx_main[1], 1));

   int direction = 0;
   if(dist_pips >= MinEmaDistance_Pips)
      direction = 1;
   else if(dist_pips <= -MinEmaDistance_Pips)
      direction = -1;
   else
      return EmptySignal("too close to EMA" + IntegerToString(EMA_Period) + " dist=" + DoubleToString(dist_pips, 1));

   // H1 trend filter: only trade in direction of H1 EMA trend
   if(UseH1Filter && !IsH1TrendAligned(direction))
      return EmptySignal("H1 EMA" + IntegerToString(H1_EMA_Period) + " not aligned with " + DirStr(direction));

   // [FIX] Removed duplicate CountOurPositions() > 0 block that was always active regardless of BlockNewEntryWhenInMarket
   if(CountPositionsByDirection(direction) >= MaxPositionsPerSide)
      return EmptySignal("side position limit reached");

   int score = ScoreDirection(direction, ema, adx_main, adx_plus, adx_minus,
                              rsi, macd_main, macd_signal, stoch_k, stoch_d,
                              bb_up, bb_mid, bb_low);
   string reason = LastScoreReason(direction, price, ema[0], dist_pips, adx_main[1]);

   // [FIX] Check for opposite positions. With AllowHedging=false, only strong signal closes opposite.
   if(CountPositionsByDirection(-direction) > 0)
   {
      if(!AllowHedging)
      {
         if(score >= OppositeCloseMinScore && CloseOppositeOnStrongSignal)
         {
            // Proceed: ExecuteSignal will close opposite first
         }
         else
         {
            return EmptySignal(reason + " opposite side open, score=" + IntegerToString(score) + " too weak to close");
         }
      }
   }

   if(AvoidChasingExtremes && IsEntryOverextended(direction, price, atr[1], bb_up[0], bb_low[0]))
      return EmptySignal(reason + " avoid chasing M1 extreme");

   double micro_range = RecentRangePips(MicroRange_Bars);
   if(micro_range < MinMicroRange_Pips)
      return EmptySignal(reason + " dead micro range=" + DoubleToString(micro_range, 1));

   if(score < MinEntryScore)
      return EmptySignal(reason + " score too low=" + IntegerToString(score));

   // [FIX] PositionsForScore thresholds now match documented ranges: 8-9/10-11/12
   int positions = PositionsForScore(score);
   int lot_cap   = MaxTotalPositions - CountOurPositions();
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
   sig.score     = score;
   sig.positions = positions;
   sig.lot       = CalcLot();
   sig.sl_price  = CalcSL(direction, ask, bid);
   sig.tp_price  = CalcTP(direction, ask, bid);
   sig.reason    = reason +
                   " score=" + IntegerToString(score) +
                   " micro=" + DoubleToString(micro_range, 1) +
                   "p spread=" + DoubleToString(spread_pips, 1) +
                   "p lot=" + DoubleToString(sig.lot, 2);
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
      // EMA slope
      if(slope > 2.0)       score += 3;
      else if(slope > 0.5)  score += 2;
      else if(slope >= 0.0) score += 1;
      else                  score -= 2;

      // ADX + DI
      if(di_ok) score += (adx_main[1] > 30.0 ? 2 : 1);

      // MACD histogram
      double macd_hist_1 = macd_main[1] - macd_signal[1];
      double macd_hist_2 = macd_main[2] - macd_signal[2];
      if(macd_hist_1 > 0.0 && macd_hist_1 > macd_hist_2) score += 2;
      else if(macd_hist_1 > 0.0)                           score += 1;
      else                                                  score -= 1;

      // [FIX] RSI zones – no more +1 bonus for bearish RSI on a buy signal
      if(rsi[1] > 55.0 && rsi[1] < 75.0) score += 3;      // sweet spot
      else if(rsi[1] >= 50.0 && rsi[1] <= 55.0) score += 2; // acceptable
      else if(rsi[1] >= 75.0)               score -= 2;    // overbought – punish
      else if(rsi[1] < 45.0)                score -= 2;    // bearish zone – punish
      // RSI [45,50): 0 points (neutral, no contradiction)

      // Stochastic
      if(stoch_k[1] < 80.0 && stoch_k[1] > stoch_d[1]) score += 1;
      else if(stoch_k[1] >= 80.0)                        score -= 1;

      // Bollinger band position
      double close_m1 = iClose(_Symbol, PERIOD_M1, 1);
      if(close_m1 > bb_mid[1] && close_m1 < bb_up[1]) score += 1;
   }
   else
   {
      // EMA slope
      if(slope < -2.0)       score += 3;
      else if(slope < -0.5)  score += 2;
      else if(slope <= 0.0)  score += 1;
      else                   score -= 2;

      // ADX + DI
      if(di_ok) score += (adx_main[1] > 30.0 ? 2 : 1);

      // MACD histogram
      double macd_hist_1 = macd_main[1] - macd_signal[1];
      double macd_hist_2 = macd_main[2] - macd_signal[2];
      if(macd_hist_1 < 0.0 && macd_hist_1 < macd_hist_2) score += 2;
      else if(macd_hist_1 < 0.0)                           score += 1;
      else                                                  score -= 1;

      // [FIX] RSI zones – no more +1 bonus for bullish RSI on a sell signal
      if(rsi[1] < 45.0 && rsi[1] > 25.0) score += 3;      // sweet spot
      else if(rsi[1] >= 45.0 && rsi[1] <= 50.0) score += 2; // acceptable
      else if(rsi[1] <= 25.0)              score -= 2;     // oversold – punish
      else if(rsi[1] > 55.0)               score -= 2;     // bullish zone – punish
      // RSI (50,55]: 0 points (neutral, no contradiction)

      // Stochastic
      if(stoch_k[1] > 20.0 && stoch_k[1] < stoch_d[1]) score += 1;
      else if(stoch_k[1] <= 20.0)                        score -= 1;

      // Bollinger band position
      double close_m1 = iClose(_Symbol, PERIOD_M1, 1);
      if(close_m1 < bb_mid[1] && close_m1 > bb_low[1]) score += 1;
   }

   return MathMin(score, 12);
}

//+------------------------------------------------------------------+
string LastScoreReason(int direction, double price, double ema_now, double dist_pips, double adx)
{
   string side = (direction == 1) ? "EMA_BUY " : "EMA_SELL ";
   return side +
          "price=" + DoubleToString(price, _Digits) +
          " ema=" + DoubleToString(ema_now, _Digits) +
          " dist=" + DoubleToString(dist_pips, 1) +
          "p ADX=" + DoubleToString(adx, 1) + " ";
}

//+------------------------------------------------------------------+
// [FIX] Thresholds now match the input group comments:
//        8-9  → WeakSignal_Positions   (1)
//        10-11 → MediumSignal_Positions (2)
//        12    → StrongSignal_Positions (3)
int PositionsForScore(int score)
{
   if(score >= 12) return StrongSignal_Positions;
   if(score >= 10) return MediumSignal_Positions;
   return WeakSignal_Positions;
}

//+------------------------------------------------------------------+
void ExecuteSignal(SignalData &sig, double ask, double bid)
{
   if(CloseOppositeOnStrongSignal && sig.score >= OppositeCloseMinScore)
      CloseOppositePositions(sig.direction);

   int opened = 0;

   for(int i = 0; i < sig.positions; i++)
   {
      // Re-check capacity before each position in the loop
      if(CountOurPositions() >= MaxTotalPositions) break;
      if(CountPositionsByDirection(sig.direction) >= MaxPositionsPerSide) break;

      ResetLastError();
      bool ok = false;
      if(sig.direction == 1)
         ok = trade.Buy(sig.lot, _Symbol, ask, sig.sl_price, sig.tp_price, "M1 v11.0 buy");
      else
         ok = trade.Sell(sig.lot, _Symbol, bid, sig.sl_price, sig.tp_price, "M1 v11.0 sell");

      if(ok)
         opened++;
      else
      {
         Print("ORDER_FAIL ", DirStr(sig.direction),
               " retcode=", trade.ResultRetcode(),
               " desc=", trade.ResultRetcodeDescription(),
               " err=", GetLastError());
         break;
      }
   }

   if(opened > 0)
   {
      last_entry_time     = TimeCurrent();
      last_entry_bar_time = iTime(_Symbol, PERIOD_M1, 0);
      if(sig.direction == 1) pyramid_levels_buy  = 0;
      else                   pyramid_levels_sell = 0;

      Print("OPEN_SIGNAL ", DirStr(sig.direction),
            " opened=", opened, "/", sig.positions,
            " lot=", DoubleToString(sig.lot, 2),
            " score=", sig.score,
            " SL=", DoubleToString(sig.sl_price, _Digits),
            " TP=", DoubleToString(sig.tp_price, _Digits),
            " reason=", sig.reason);
   }
}

//+------------------------------------------------------------------+
// [UPDATED] ManagePositions: breakeven + trailing stop instead of
//           money-based emergency close. Hard SL on orders now handles
//           emergency close at broker level.
void ManagePositions()
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double atr = GetCurrentATR();

   // ATR-based thresholds in price units
   double be_dist    = (BreakevenAt_ATR  > 0.0) ? atr * BreakevenAt_ATR  : 0.0;
   double trail_act  = (TrailActivate_ATR > 0.0) ? atr * TrailActivate_ATR : 0.0;
   double trail_step = (TrailStep_ATR    > 0.0) ? atr * TrailStep_ATR    : 0.0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!IsOurPosition(ticket))
         continue;

      int    pos_type   = (int)PositionGetInteger(POSITION_TYPE);
      double open_price = PositionGetDouble(POSITION_PRICE_OPEN);
      double cur_sl     = PositionGetDouble(POSITION_SL);
      double cur_tp     = PositionGetDouble(POSITION_TP);

      double profit_dist = (pos_type == POSITION_TYPE_BUY)
                          ? bid - open_price
                          : open_price - ask;
      double profit_pips = profit_dist / PipSize;

      double new_sl = cur_sl;
      bool   modify = false;

      // Step 1: Breakeven – move SL to open_price once profit >= ATR * BreakevenAt_ATR
      if(be_dist > 0.0 && profit_dist >= be_dist)
      {
         double be_sl;
         if(pos_type == POSITION_TYPE_BUY)
         {
            be_sl = NormalizeDouble(open_price + _Point, _Digits);
            if(be_sl > cur_sl + _Point) { new_sl = be_sl; modify = true; }
         }
         else
         {
            be_sl = NormalizeDouble(open_price - _Point, _Digits);
            if(cur_sl <= 0.0 || be_sl < cur_sl - _Point) { new_sl = be_sl; modify = true; }
         }
      }

      // Step 2: Trailing stop – activates at ATR*TrailActivate_ATR, trails ATR*TrailStep_ATR
      if(trail_act > 0.0 && profit_dist >= trail_act && trail_step > 0.0)
      {
         double trail_sl;
         if(pos_type == POSITION_TYPE_BUY)
         {
            trail_sl = NormalizeDouble(bid - trail_step, _Digits);
            if(trail_sl > new_sl + _Point) { new_sl = trail_sl; modify = true; }
         }
         else
         {
            trail_sl = NormalizeDouble(ask + trail_step, _Digits);
            if(cur_sl <= 0.0 || trail_sl < new_sl - _Point) { new_sl = trail_sl; modify = true; }
         }
      }

      if(modify)
      {
         if(trade.PositionModify(ticket, new_sl, cur_tp))
            Print("SL_MODIFY ticket=", ticket,
                  " profitPips=", DoubleToString(profit_pips, 1),
                  " ATRpips=", DoubleToString(atr / PipSize, 1),
                  " newSL=", DoubleToString(new_sl, _Digits));
      }
   }
}

//+------------------------------------------------------------------+
// [RENAMED & LOGIC CHANGED] Pyramid adds only to profitable side.
//  Previously tried to average into losing positions (drawdown trigger).
//  Now requires the side to be in profit before adding.
void CheckSmartPyramidAdds(double ask, double bid)
{
   TryPyramidAdd(1,  ask, bid);
   TryPyramidAdd(-1, ask, bid);
}

//+------------------------------------------------------------------+
void TryPyramidAdd(int direction, double ask, double bid)
{
   int side_count = CountPositionsByDirection(direction);
   if(side_count <= 0 || side_count >= MaxPositionsPerSide)
      return;
   if(CountOurPositions() >= MaxTotalPositions)
      return;

   int      levels   = (direction == 1) ? pyramid_levels_buy    : pyramid_levels_sell;
   datetime last_add = (direction == 1) ? last_pyramid_buy_time : last_pyramid_sell_time;
   if(levels >= MaxPyramidAddsPerSide)
      return;
   if(TimeCurrent() - last_add < MinSecondsBetweenAdds)
      return;

   // [CHANGED] Require the SIDE to be PROFITABLE before pyramiding
   double side_profit_pips = SideProfitPips(direction);
   if(side_profit_pips < PyramidMinProfitPips)
      return;

   if(!IsM1DirectionStillValid(direction))
      return;

   int py_score = PullbackSignalScore(direction);
   if(py_score < PullbackMinScore)
      return;

   if(!IsPyramidZone(direction, ask, bid))
      return;

   double lot = CalcLot(); // Same BaseLot for pyramid adds

   double sl = CalcSL(direction, ask, bid);
   double tp = CalcTP(direction, ask, bid);

   ResetLastError();
   bool ok = (direction == 1)
             ? trade.Buy(lot, _Symbol, ask, sl, tp, "M1 v11.0 pyramid buy")
             : trade.Sell(lot, _Symbol, bid, sl, tp, "M1 v11.0 pyramid sell");

   if(ok)
   {
      if(direction == 1) { pyramid_levels_buy++;  last_pyramid_buy_time  = TimeCurrent(); }
      else               { pyramid_levels_sell++; last_pyramid_sell_time = TimeCurrent(); }
      last_entry_time     = TimeCurrent();
      last_entry_bar_time = iTime(_Symbol, PERIOD_M1, 0);
      Print("PYRAMID_ADD ", DirStr(direction),
            " level=", levels + 1,
            " lot=", DoubleToString(lot, 2),
            " score=", py_score,
            " sideProfitPips=", DoubleToString(side_profit_pips, 1),
            " SL=", DoubleToString(sl, _Digits),
            " TP=", DoubleToString(tp, _Digits));
   }
   else
   {
      Print("PYRAMID_FAIL ", DirStr(direction),
            " retcode=", trade.ResultRetcode(),
            " desc=", trade.ResultRetcodeDescription());
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

   if(adx_main[1] < ADX_Min) return false;

   double price = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) +
                   SymbolInfoDouble(_Symbol, SYMBOL_BID)) * 0.5;
   double slope     = (ema[0] - ema[EMA_Slope_Bars]) / PipSize;
   double macd_hist = macd_main[1] - macd_signal[1];

   if(direction == 1)
   {
      if(price < ema[0] && slope < 0.0)            return false;
      if(RequireDIDirection && adx_plus[1] <= adx_minus[1]) return false;
      if(macd_hist < 0.0 && rsi[1] < 50.0)          return false;
      if(stoch_k[1] < stoch_d[1] && rsi[1] < 48.0) return false;
      return true;
   }

   if(price > ema[0] && slope > 0.0)            return false;
   if(RequireDIDirection && adx_minus[1] <= adx_plus[1]) return false;
   if(macd_hist > 0.0 && rsi[1] > 50.0)          return false;
   if(stoch_k[1] > stoch_d[1] && rsi[1] > 52.0) return false;
   return true;
}

//+------------------------------------------------------------------+
int PullbackSignalScore(int direction)
{
   double ema[], adx_main[], adx_plus[], adx_minus[];
   double rsi[], macd_main[], macd_signal[], stoch_k[], stoch_d[];
   double bb_up[], bb_mid[], bb_low[];
   int ema_count = MathMax(EMA_Slope_Bars + 2, 5);

   if(!SafeCopy(h_ema,   0, ema,         ema_count)) return -99;
   if(!SafeCopy(h_adx,   0, adx_main,    4))         return -99;
   if(!SafeCopy(h_adx,   1, adx_plus,    4))         return -99;
   if(!SafeCopy(h_adx,   2, adx_minus,   4))         return -99;
   if(!SafeCopy(h_rsi,   0, rsi,         4))         return -99;
   if(!SafeCopy(h_macd,  0, macd_main,   4))         return -99;
   if(!SafeCopy(h_macd,  1, macd_signal, 4))         return -99;
   if(!SafeCopy(h_stoch, 0, stoch_k,     4))         return -99;
   if(!SafeCopy(h_stoch, 1, stoch_d,     4))         return -99;
   if(!SafeCopy(h_bb,    0, bb_up,       4))         return -99;
   if(!SafeCopy(h_bb,    1, bb_mid,      4))         return -99;
   if(!SafeCopy(h_bb,    2, bb_low,      4))         return -99;

   if(adx_main[1] < ADX_Min) return -99;

   return ScoreDirection(direction, ema, adx_main, adx_plus, adx_minus,
                         rsi, macd_main, macd_signal, stoch_k, stoch_d,
                         bb_up, bb_mid, bb_low);
}

//+------------------------------------------------------------------+
// Price zone check for pyramid add: near EMA or BB mid on a pullback candle
bool IsPyramidZone(int direction, double ask, double bid)
{
   double ema[], bb_up[], bb_mid[], bb_low[], atr[];
   if(!SafeCopy(h_ema, 0, ema,    3)) return false;
   if(!SafeCopy(h_bb,  0, bb_up,  3)) return false;
   if(!SafeCopy(h_bb,  1, bb_mid, 3)) return false;
   if(!SafeCopy(h_bb,  2, bb_low, 3)) return false;
   if(!SafeCopy(h_atr, 0, atr,    3)) return false;

   double price    = (ask + bid) * 0.5;
   double atr_pips = atr[1] / PipSize;
   double max_dist = MathMax(PyramidZonePips, atr_pips * PyramidAtrPart);

   double open0  = iOpen (_Symbol, PERIOD_M1, 0);
   double high0  = iHigh (_Symbol, PERIOD_M1, 0);
   double low0   = iLow  (_Symbol, PERIOD_M1, 0);
   double close0 = iClose(_Symbol, PERIOD_M1, 0);
   if(open0 <= 0.0 || high0 <= 0.0 || low0 <= 0.0 || close0 <= 0.0) return false;

   if(direction == 1)
   {
      bool pullback_bar  = close0 < open0;
      bool near_support  = (MathAbs(price - ema[0])    / PipSize <= max_dist) ||
                           (MathAbs(price - bb_mid[0]) / PipSize <= max_dist) ||
                           ((price - low0)              / PipSize <= ExtremeBuffer_Pips);
      bool not_at_high   = ((high0 - price) / PipSize > ExtremeBuffer_Pips);
      return pullback_bar && near_support && not_at_high;
   }

   bool pullback_bar = close0 > open0;
   bool near_resist  = (MathAbs(price - ema[0])    / PipSize <= max_dist) ||
                       (MathAbs(price - bb_mid[0]) / PipSize <= max_dist) ||
                       ((high0 - price)             / PipSize <= ExtremeBuffer_Pips);
   bool not_at_low   = ((price - low0) / PipSize > ExtremeBuffer_Pips);
   return pullback_bar && near_resist && not_at_low;
}

//+------------------------------------------------------------------+
bool IsEntryOverextended(int direction, double price, double atr_value,
                         double bb_up, double bb_low)
{
   if(!AvoidChasingExtremes) return false;

   double open0  = iOpen (_Symbol, PERIOD_M1, 0);
   double high0  = iHigh (_Symbol, PERIOD_M1, 0);
   double low0   = iLow  (_Symbol, PERIOD_M1, 0);
   double close0 = iClose(_Symbol, PERIOD_M1, 0);
   if(open0 <= 0.0 || high0 <= 0.0 || low0 <= 0.0 || close0 <= 0.0) return false;

   double body_pips = MathAbs(close0 - open0) / PipSize;
   double atr_pips  = (atr_value > 0.0) ? atr_value / PipSize : 0.0;
   double max_body  = MathMax(ExtremeBuffer_Pips, atr_pips * MaxChaseBodyAtrPart);
   if(body_pips < max_body) return false;

   if(direction == 1)
   {
      bool near_high        = ((high0 - price) / PipSize <= ExtremeBuffer_Pips);
      bool near_upper_band  = (bb_up > 0.0 && price >= bb_up - ExtremeBuffer_Pips * PipSize);
      return near_high || near_upper_band;
   }

   bool near_low        = ((price - low0) / PipSize <= ExtremeBuffer_Pips);
   bool near_lower_band = (bb_low > 0.0 && price <= bb_low + ExtremeBuffer_Pips * PipSize);
   return near_low || near_lower_band;
}

//+------------------------------------------------------------------+
// [NEW] H1 trend filter: only buy when H1 close is above H1 EMA, vice versa
bool IsH1TrendAligned(int direction)
{
   if(!UseH1Filter) return true;

   double h1_ema[];
   ArraySetAsSeries(h1_ema, true);
   int copied = CopyBuffer(h_h1ema, 0, 0, 3, h1_ema);
   if(copied < 2) return true; // Don't block if H1 data not ready yet

   double h1_close = iClose(_Symbol, PERIOD_H1, 1);
   if(h1_close <= 0.0) return true;

   if(direction == 1) return h1_close > h1_ema[1];
   return h1_close < h1_ema[1];
}

//+------------------------------------------------------------------+
// GetCurrentATR: read latest completed-bar ATR value
double GetCurrentATR()
{
   double atr[];
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(h_atr, 0, 0, 3, atr) < 2 || atr[1] <= 0.0)
      return MinSL_Pips * PipSize; // fallback
   return atr[1];
}

//+------------------------------------------------------------------+
// CalcSLDist: returns SL distance in price (not pips)
// = max(ATR*SL_ATR_Mult, MinSL_Pips*PipSize, spread*2)
double CalcSLDist(double ask, double bid)
{
   double atr    = GetCurrentATR();
   double spread = ask - bid;
   double dist   = atr * SL_ATR_Mult;
   dist = MathMax(dist, MinSL_Pips * PipSize);  // floor in pips
   dist = MathMax(dist, spread * 2.0);           // must clear spread 2x
   return dist;
}

//+------------------------------------------------------------------+
// [FIX] CalcSL: ATR-based SL, always > spread
double CalcSL(int direction, double ask, double bid)
{
   double sl_dist = CalcSLDist(ask, bid);
   double sl      = (direction == 1) ? bid - sl_dist : ask + sl_dist;
   sl = NormalizeInitialStop(direction, sl, ask, bid);
   return NormalizeDouble(sl, _Digits);
}

//+------------------------------------------------------------------+
// [FIX] CalcTP: ATR-based TP (TP_ATR_Mult * ATR from entry)
double CalcTP(int direction, double ask, double bid)
{
   if(TP_ATR_Mult <= 0.0) return 0.0;
   double atr  = GetCurrentATR();
   double dist = atr * TP_ATR_Mult;
   double tp   = (direction == 1) ? ask + dist : bid - dist;
   return NormalizeDouble(tp, _Digits);
}

//+------------------------------------------------------------------+
// CalcLot: returns fixed BaseLot (user-controlled, no auto-sizing)
double CalcLot()
{
   return NormLot(BaseLot);
}

//+------------------------------------------------------------------+
double NormalizeInitialStop(int direction, double sl, double ask, double bid)
{
   int stops_level  = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   int freeze_level = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   int min_points   = MathMax(stops_level, freeze_level) + 2;
   double min_dist  = MathMax(min_points * _Point, _Point);

   if(direction == 1) return MathMin(sl, bid - min_dist);
   return MathMax(sl, ask + min_dist);
}

//+------------------------------------------------------------------+
bool CanOpenNewEntry()
{
   if(TimeCurrent() - last_entry_time < MinSecondsBetweenEntries) return false;

   if(OneEntryPerM1Bar)
   {
      if(iTime(_Symbol, PERIOD_M1, 0) == last_entry_bar_time) return false;
   }

   return true;
}

//+------------------------------------------------------------------+
bool IsTradingSession()
{
   // Convert broker server time to GMT, then check session hours
   datetime gmt = TimeCurrent() - GMT_Offset * 3600;
   MqlDateTime tm;
   TimeToStruct(gmt, tm);
   return (tm.hour >= Session_Start_H && tm.hour < Session_End_H);
}

//+------------------------------------------------------------------+
bool SafeCopy(int handle, int buffer, double &arr[], int count)
{
   if(handle == INVALID_HANDLE) return false;
   ArraySetAsSeries(arr, true);
   int copied = CopyBuffer(handle, buffer, 0, count, arr);
   if(copied < count)
   {
      if(DebugMode) Print("COPY_FAIL handle=", handle, " buf=", buffer, " got=", copied);
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
bool IsOurPosition(ulong ticket)
{
   if(ticket == 0) return false;
   if(PositionGetString(POSITION_SYMBOL) != _Symbol) return false;
   if(!IsManagedMagic(PositionGetInteger(POSITION_MAGIC))) return false;
   return true;
}

//+------------------------------------------------------------------+
bool IsManagedMagic(long magic)
{
   if(magic == MAGIC) return true;
   if(!ManageLegacyMagic) return false;
   return (magic == 20261000 ||
           magic == 202604282 ||
           magic == 202604281 ||
           magic == 20260902);
}

//+------------------------------------------------------------------+
int CountOurPositions()
{
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(IsOurPosition(ticket)) n++;
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
      if(!IsOurPosition(ticket)) continue;
      if(PositionGetInteger(POSITION_TYPE) == wanted) n++;
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
      if(!IsOurPosition(ticket)) continue;
      if(PositionGetInteger(POSITION_TYPE) != opposite) continue;
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
   int lo = iLowest (_Symbol, PERIOD_M1, MODE_LOW,  count, 1);
   if(hi < 0 || lo < 0) return 0.0;
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
      if(!IsOurPosition(ticket)) continue;
      if(PositionGetInteger(POSITION_TYPE) == wanted)
         profit += PositionGetDouble(POSITION_PROFIT);
   }
   return profit;
}

//+------------------------------------------------------------------+
// [NEW] SideProfitPips: volume-weighted average profit in pips
double SideProfitPips(int direction)
{
   double weighted_pips = 0.0;
   double vol_sum       = 0.0;
   long   wanted        = (direction == 1) ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!IsOurPosition(ticket)) continue;
      if(PositionGetInteger(POSITION_TYPE) != wanted) continue;

      double open_price  = PositionGetDouble(POSITION_PRICE_OPEN);
      double volume      = PositionGetDouble(POSITION_VOLUME);
      double profit_pips = (direction == 1)
                          ? (bid - open_price) / PipSize
                          : (open_price - ask) / PipSize;
      weighted_pips += profit_pips * volume;
      vol_sum       += volume;
   }

   if(vol_sum <= 0.0) return 0.0;
   return weighted_pips / vol_sum;
}

//+------------------------------------------------------------------+
double SideAverageOpenPrice(int direction)
{
   double weighted_sum = 0.0;
   double volume_sum   = 0.0;
   long wanted = (direction == 1) ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!IsOurPosition(ticket)) continue;
      if(PositionGetInteger(POSITION_TYPE) != wanted) continue;
      double volume = PositionGetDouble(POSITION_VOLUME);
      weighted_sum += PositionGetDouble(POSITION_PRICE_OPEN) * volume;
      volume_sum   += volume;
   }

   if(volume_sum <= 0.0) return 0.0;
   return weighted_sum / volume_sum;
}

//+------------------------------------------------------------------+
double NormLot(double lot)
{
   double step    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double min_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double max_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(step <= 0.0) step = 0.01;
   lot = MathFloor(lot / step) * step;
   return MathMax(min_lot, MathMin(max_lot, lot));
}

//+------------------------------------------------------------------+
double CalcPipSize()
{
   if(_Digits == 3 || _Digits == 5) return _Point * 10.0;
   return _Point;
}

//+------------------------------------------------------------------+
void PrintOpenPositionsDebug()
{
   if(!DebugOpenPositions) return;
   datetime now = TimeCurrent();
   if(now - last_positions_debug_time < DebugPositionsEverySeconds) return;
   last_positions_debug_time = now;

   Print("POSITIONS ", EA_Version,
         " | BUY count=",  CountPositionsByDirection(1),
         " avg=",  DoubleToString(SideAverageOpenPrice(1), _Digits),
         " PnLpips=", DoubleToString(SideProfitPips(1), 1),
         " pyram=", pyramid_levels_buy,
         " || SELL count=", CountPositionsByDirection(-1),
         " avg=",  DoubleToString(SideAverageOpenPrice(-1), _Digits),
         " PnLpips=", DoubleToString(SideProfitPips(-1), 1),
         " pyram=", pyramid_levels_sell);
}

//+------------------------------------------------------------------+
string DirStr(int direction)
{
   if(direction ==  1) return "BUY";
   if(direction == -1) return "SELL";
   return "NEUTRAL";
}
//+------------------------------------------------------------------+
