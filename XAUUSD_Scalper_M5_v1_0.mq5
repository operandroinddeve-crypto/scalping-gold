//+------------------------------------------------------------------+
//|              XAUUSD_Scalper_M5_v1_0.mq5                          |
//|  GOLD M5 Trend-Scalper with Smart Stops                          |
//|                                                                   |
//|  Architecture:                                                    |
//|  - Timeframe: M5 (signals) + M15 (trend filter)                  |
//|  - Entry: EMA crossover stack + MACD momentum + RSI zone         |
//|  - Sizing: lot scales 0.01→0.05 by signal strength (1-5 pts)    |
//|  - Averaging: adds to position when trend confirms direction      |
//|  - Hold: keeps trade open while trend indicators stay positive   |
//|  - Exit: closes when momentum reverses (not fixed TP)            |
//|  - Smart SL: ATR-based + swing structure + false-breakout buffer |
//|  - Trailing: activates after 1xATR profit, trails 0.5xATR       |
//|  - Breakeven: moves SL to entry+1pip after 0.5xATR profit       |
//+------------------------------------------------------------------+
#property copyright "2026 AndroindDeve + AI"
#property version   "1.0"
#property strict

#include <Trade\Trade.mqh>
CTrade trade;

//=== ─── INPUTS ────────────────────────────────────────────────────
input group "═══ Lot Sizing ═══"
input double  LotMin           = 0.01;  // Minimum lot (weak signal, score 1)
input double  LotMax           = 0.05;  // Maximum lot (strong signal, score 5)
// Lot is interpolated linearly: lot = LotMin + (LotMax-LotMin)*(score-1)/4

input group "═══ Averaging ═══"
input bool    UseAveraging        = true;
input int     MaxAveragePositions = 5;       // Max total positions per direction
input double  AverageStepATR      = 0.4;     // Min distance from last entry (ATR multiples)
input int     AverageMinScore     = 3;       // Minimum signal score to average in
input int     MinSecondsBetweenAvg = 60;     // Cooldown between averaging entries

input group "═══ Smart Stop Loss ═══"
input double  SL_ATR_Base      = 1.8;  // Base SL distance = ATR * this
input double  SL_SwingLookback = 10;   // Bars to look back for swing high/low
// SL = max(ATR*SL_ATR_Base, swing_point) with false-breakout buffer
input double  FalseBreakBuffer = 0.3;  // Extra ATR buffer beyond swing to absorb fakeouts
input double  MinSL_Pips       = 30.0; // Absolute minimum SL in pips

input group "═══ Profit Management ═══"
// No fixed TP – exit driven by indicator reversal
input double  BreakevenATR     = 0.5;  // Move SL to breakeven after profit >= ATR*this
input double  TrailStartATR    = 1.0;  // Start trailing after profit >= ATR*this
input double  TrailDistATR     = 0.5;  // Trailing SL stays ATR*this behind price
input double  PartialClosePct  = 50.0; // Close this % of position at TrailStartATR profit (0=off)

input group "═══ Signal & Entry ═══"
input int     MinEntryScore    = 3;    // Minimum score (1-5) to open a trade
input int     MaxTotalPositions = 10;  // Absolute max open positions (all directions)
input int     MinSecondsBetweenEntries = 60;
input bool    OneEntryPerM5Bar  = true;

input group "═══ M5 Indicators ═══"
input int     Fast_EMA         = 8;    // Fast EMA (trend direction on M5)
input int     Mid_EMA          = 21;   // Mid EMA  (trend confirmation)
input int     Slow_EMA         = 50;   // Slow EMA (major trend bias)
input int     MACD_Fast        = 5;    // MACD fast period
input int     MACD_Slow        = 13;   // MACD slow period
input int     MACD_Signal      = 3;    // MACD signal period
input int     RSI_Period       = 9;    // RSI period
input int     ATR_Period       = 14;   // ATR period for SL/TP/sizing
input int     Stoch_K          = 5;    // Stochastic %K
input int     Stoch_D          = 3;    // Stochastic %D
input int     Stoch_Slowing    = 3;

input group "═══ M15 Trend Filter ═══"
input bool    UseM15Filter     = true;
input int     M15_EMA_Period   = 34;   // M15 trend EMA – only trade in its direction

input group "═══ Session ═══"
input int     GMT_Offset       = 3;    // Broker server GMT offset
input int     Session_Start_H  = 7;    // GMT session open
input int     Session_End_H    = 21;   // GMT session close
input bool    CloseAllEOD      = true; // Close all positions at session end

input group "═══ Filters ═══"
input double  MaxSpreadPips    = 50.0; // Max allowed spread in pips
input bool    RequireCandleConfirm = true; // Wait for M5 bar close before entry
input int     DeviationPoints  = 30;
input bool    ManageLegacyMagic = true;

input group "═══ Debug ═══"
input bool    DebugMode        = true;
input bool    DebugPositions   = true;
input int     DebugEverySeconds = 30;

//=== ─── INDICATOR HANDLES ─────────────────────────────────────────
int h_fast_ema  = INVALID_HANDLE;
int h_mid_ema   = INVALID_HANDLE;
int h_slow_ema  = INVALID_HANDLE;
int h_macd      = INVALID_HANDLE;
int h_rsi       = INVALID_HANDLE;
int h_atr       = INVALID_HANDLE;
int h_stoch     = INVALID_HANDLE;
int h_m15_ema   = INVALID_HANDLE;

//=== ─── GLOBALS ───────────────────────────────────────────────────
long     MAGIC             = 20260001;
double   PipSize           = 0.0;
datetime last_entry_time   = 0;
datetime last_entry_bar    = 0;
datetime last_avg_buy_time = 0;
datetime last_avg_sell_time = 0;
datetime last_debug_time   = 0;
bool     partial_closed_buy  = false; // Tracks if partial close already done for buys
bool     partial_closed_sell = false;

struct SignalResult
{
   int    direction; // 1=buy, -1=sell, 0=none
   int    score;     // 1-5 signal quality
   double lot;
   double sl;
   double tp;        // always 0 – we use dynamic exit
   string reason;
};

//+------------------------------------------------------------------+
int OnInit()
{
   PipSize = (_Digits == 3 || _Digits == 5) ? _Point * 10.0 : _Point;

   h_fast_ema = iMA(_Symbol, PERIOD_M5, Fast_EMA, 0, MODE_EMA, PRICE_CLOSE);
   h_mid_ema  = iMA(_Symbol, PERIOD_M5, Mid_EMA,  0, MODE_EMA, PRICE_CLOSE);
   h_slow_ema = iMA(_Symbol, PERIOD_M5, Slow_EMA, 0, MODE_EMA, PRICE_CLOSE);
   h_macd     = iMACD(_Symbol, PERIOD_M5, MACD_Fast, MACD_Slow, MACD_Signal, PRICE_CLOSE);
   h_rsi      = iRSI(_Symbol, PERIOD_M5, RSI_Period, PRICE_CLOSE);
   h_atr      = iATR(_Symbol, PERIOD_M5, ATR_Period);
   h_stoch    = iStochastic(_Symbol, PERIOD_M5, Stoch_K, Stoch_D, Stoch_Slowing, MODE_SMA, STO_LOWHIGH);
   h_m15_ema  = iMA(_Symbol, PERIOD_M15, M15_EMA_Period, 0, MODE_EMA, PRICE_CLOSE);

   if(h_fast_ema == INVALID_HANDLE || h_mid_ema == INVALID_HANDLE ||
      h_slow_ema == INVALID_HANDLE || h_macd == INVALID_HANDLE ||
      h_rsi == INVALID_HANDLE || h_atr == INVALID_HANDLE ||
      h_stoch == INVALID_HANDLE || h_m15_ema == INVALID_HANDLE)
   {
      Print("INIT FAILED: could not create indicator handles");
      return INIT_FAILED;
   }

   trade.SetExpertMagicNumber(MAGIC);
   trade.SetDeviationInPoints(DeviationPoints);
   trade.SetAsyncMode(false);

   Print("XAUUSD M5 Scalper v1.0 | Lot=", LotMin, "-", LotMax,
         " MaxPos=", MaxTotalPositions, " Avg=", UseAveraging,
         " M15Filter=", UseM15Filter);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(h_fast_ema);
   IndicatorRelease(h_mid_ema);
   IndicatorRelease(h_slow_ema);
   IndicatorRelease(h_macd);
   IndicatorRelease(h_rsi);
   IndicatorRelease(h_atr);
   IndicatorRelease(h_stoch);
   IndicatorRelease(h_m15_ema);
}

//+------------------------------------------------------------------+
void OnTick()
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0.0 || bid <= 0.0) return;

   // ── 1. Manage existing positions (SL/TP/trail/breakeven/exit) ──
   ManagePositions(ask, bid);
   PrintDebug();

   // ── 2. End-of-session close ───────────────────────────────────
   if(CloseAllEOD && IsSessionEnd())
   {
      CloseAllOurPositions("EOD");
      return;
   }

   if(!IsTradingSession()) return;

   // ── 3. Spread guard ──────────────────────────────────────────
   double spread_pips = (ask - bid) / PipSize;
   if(MaxSpreadPips > 0.0 && spread_pips > MaxSpreadPips) return;

   // ── 4. Wait for M5 bar close (avoid acting on unfinished bar) ─
   if(RequireCandleConfirm)
   {
      datetime bar0 = iTime(_Symbol, PERIOD_M5, 0);
      if(bar0 == last_entry_bar) return; // already entered this bar
   }

   // ── 5. Load all indicator data ───────────────────────────────
   IndicatorData idata;
   if(!LoadIndicators(idata)) return;

   // ── 6. Try averaging add on existing position ─────────────────
   if(UseAveraging) TryAverage(idata, ask, bid);

   // ── 7. New signal entry ───────────────────────────────────────
   if(CountAllPositions() >= MaxTotalPositions) return;
   if(TimeCurrent() - last_entry_time < MinSecondsBetweenEntries) return;

   SignalResult sig = BuildSignal(idata, ask, bid);
   if(DebugMode && sig.direction != 0)
      Print("SIGNAL ", DirStr(sig.direction), " score=", sig.score,
            " lot=", DoubleToString(sig.lot, 2), " SL=", DoubleToString(sig.sl, _Digits),
            " | ", sig.reason);

   if(sig.direction != 0 && sig.score >= MinEntryScore)
      OpenPosition(sig, ask, bid);
}

//+------------------------------------------------------------------+
//  Indicator data container
struct IndicatorData
{
   double fast_ema[4], mid_ema[4], slow_ema[4];
   double macd_main[4], macd_sig[4];
   double rsi[4];
   double atr[4];
   double stoch_k[4], stoch_d[4];
   double m15_ema[4];
   double atr_val;   // ATR[1] shortcut
};

//+------------------------------------------------------------------+
bool LoadIndicators(IndicatorData &d)
{
   if(!SC(h_fast_ema, 0, d.fast_ema, 4)) return false;
   if(!SC(h_mid_ema,  0, d.mid_ema,  4)) return false;
   if(!SC(h_slow_ema, 0, d.slow_ema, 4)) return false;
   if(!SC(h_macd,     0, d.macd_main,4)) return false;
   if(!SC(h_macd,     1, d.macd_sig, 4)) return false;
   if(!SC(h_rsi,      0, d.rsi,      4)) return false;
   if(!SC(h_atr,      0, d.atr,      4)) return false;
   if(!SC(h_stoch,    0, d.stoch_k,  4)) return false;
   if(!SC(h_stoch,    1, d.stoch_d,  4)) return false;
   if(!SC(h_m15_ema,  0, d.m15_ema,  4)) return false;

   d.atr_val = (d.atr[1] > 0.0) ? d.atr[1] : MinSL_Pips * PipSize;
   return true;
}

//+------------------------------------------------------------------+
//  Core signal builder – returns score 1-5 and direction
SignalResult BuildSignal(IndicatorData &d, double ask, double bid)
{
   SignalResult res;
   res.direction = 0; res.score = 0; res.lot = LotMin;
   res.sl = 0.0; res.tp = 0.0; res.reason = "";

   double price = (ask + bid) * 0.5;

   // ── M15 trend filter ─────────────────────────────────────────
   if(UseM15Filter)
   {
      double m15_close = iClose(_Symbol, PERIOD_M15, 1);
      bool m15_bull = m15_close > d.m15_ema[1];
      bool m15_bear = m15_close < d.m15_ema[1];
      if(!m15_bull && !m15_bear) return res;

      // Store for scoring below
      res.reason = m15_bull ? "M15↑ " : "M15↓ ";
   }

   // ── EMA Stack: Fast > Mid > Slow = strong bull,  reverse = bear ─
   bool ema_bull = d.fast_ema[1] > d.mid_ema[1] && d.mid_ema[1] > d.slow_ema[1];
   bool ema_bear = d.fast_ema[1] < d.mid_ema[1] && d.mid_ema[1] < d.slow_ema[1];
   if(!ema_bull && !ema_bear) return res; // mixed – no trade

   int direction = ema_bull ? 1 : -1;

   // Enforce M15 alignment
   if(UseM15Filter)
   {
      double m15_close = iClose(_Symbol, PERIOD_M15, 1);
      bool m15_aligned = (direction == 1) ? m15_close > d.m15_ema[1]
                                          : m15_close < d.m15_ema[1];
      if(!m15_aligned) return res;
   }

   int score = 0;
   string why = res.reason + (direction == 1 ? "EMA▲ " : "EMA▼ ");

   // ── Score 1: EMA slope (fast EMA trending) ───────────────────
   double fast_slope = (d.fast_ema[1] - d.fast_ema[3]) / PipSize;
   if(direction == 1 && fast_slope > 1.0) { score++; why += "Slope+ "; }
   else if(direction == -1 && fast_slope < -1.0) { score++; why += "Slope- "; }

   // ── Score 2: MACD histogram in direction and growing ─────────
   double hist1 = d.macd_main[1] - d.macd_sig[1];
   double hist2 = d.macd_main[2] - d.macd_sig[2];
   bool macd_bull = hist1 > 0.0 && hist1 >= hist2;
   bool macd_bear = hist1 < 0.0 && hist1 <= hist2;
   if((direction == 1 && macd_bull) || (direction == -1 && macd_bear))
      { score++; why += "MACD✓ "; }
   else
      return res; // MACD must confirm – hard requirement

   // ── Score 3: RSI momentum zone ───────────────────────────────
   // Buy: RSI 50-75 (bullish momentum, not overbought)
   // Sell: RSI 25-50 (bearish momentum, not oversold)
   if(direction == 1 && d.rsi[1] >= 50.0 && d.rsi[1] <= 75.0)
      { score++; why += "RSI✓ "; }
   else if(direction == -1 && d.rsi[1] <= 50.0 && d.rsi[1] >= 25.0)
      { score++; why += "RSI✓ "; }

   // ── Score 4: Stochastic aligned and not extreme ───────────────
   bool stoch_bull = d.stoch_k[1] > d.stoch_d[1] && d.stoch_k[1] < 80.0;
   bool stoch_bear = d.stoch_k[1] < d.stoch_d[1] && d.stoch_k[1] > 20.0;
   if((direction == 1 && stoch_bull) || (direction == -1 && stoch_bear))
      { score++; why += "Stoch✓ "; }

   // ── Score 5: Price vs Mid EMA gap (momentum strength) ────────
   double ema_gap_pips = MathAbs(price - d.mid_ema[1]) / PipSize;
   double atr_pips     = d.atr_val / PipSize;
   if(ema_gap_pips > atr_pips * 0.15 && ema_gap_pips < atr_pips * 0.8)
      { score++; why += "EMAGap✓ "; }

   if(score < 1) return res;

   // ── Lot sizing: scales from LotMin to LotMax by score ────────
   double lot_range = LotMax - LotMin;
   double lot = LotMin + lot_range * (double)(score - 1) / 4.0;
   lot = NormLot(lot);

   // ── Smart SL: ATR + swing structure + false-breakout buffer ──
   double sl = CalcSmartSL(direction, ask, bid, d.atr_val);

   res.direction = direction;
   res.score     = score;
   res.lot       = lot;
   res.sl        = sl;
   res.tp        = 0.0; // dynamic exit, no fixed TP
   res.reason    = why + "score=" + IntegerToString(score)
                   + " atr=" + DoubleToString(atr_pips, 1) + "p";
   return res;
}

//+------------------------------------------------------------------+
//  Smart SL: furthest of (ATR*base, swing point) + false-breakout buffer
double CalcSmartSL(int direction, double ask, double bid, double atr_val)
{
   int lookback = (int)SL_SwingLookback;
   double fb_buf = atr_val * FalseBreakBuffer;

   // Swing-based SL
   double swing_sl;
   if(direction == 1)
   {
      // SL below recent swing low
      int lo_bar = iLowest(_Symbol, PERIOD_M5, MODE_LOW, lookback, 1);
      double swing_low = (lo_bar >= 0) ? iLow(_Symbol, PERIOD_M5, lo_bar) : bid;
      swing_sl = swing_low - fb_buf; // false-breakout buffer below swing
   }
   else
   {
      // SL above recent swing high
      int hi_bar = iHighest(_Symbol, PERIOD_M5, MODE_HIGH, lookback, 1);
      double swing_high = (hi_bar >= 0) ? iHigh(_Symbol, PERIOD_M5, hi_bar) : ask;
      swing_sl = swing_high + fb_buf;
   }

   // ATR-based SL
   double atr_sl = (direction == 1) ? bid - atr_val * SL_ATR_Base
                                     : ask + atr_val * SL_ATR_Base;

   // Minimum pips SL
   double min_sl = (direction == 1) ? bid - MinSL_Pips * PipSize
                                    : ask + MinSL_Pips * PipSize;

   // Take the most protective (furthest from current price)
   double sl;
   if(direction == 1)
      sl = MathMin(swing_sl, MathMin(atr_sl, min_sl)); // lowest of all
   else
      sl = MathMax(swing_sl, MathMax(atr_sl, min_sl)); // highest of all

   // Enforce broker stops level
   sl = NormalizeStop(direction, sl, ask, bid);
   return NormalizeDouble(sl, _Digits);
}

//+------------------------------------------------------------------+
void OpenPosition(SignalResult &sig, double ask, double bid)
{
   if(CountPositionsByDir(sig.direction) >= MaxAveragePositions) return;

   ResetLastError();
   bool ok = false;
   if(sig.direction == 1)
      ok = trade.Buy(sig.lot, _Symbol, ask, sig.sl, 0.0, "M5v1 BUY s=" + IntegerToString(sig.score));
   else
      ok = trade.Sell(sig.lot, _Symbol, bid, sig.sl, 0.0, "M5v1 SELL s=" + IntegerToString(sig.score));

   if(ok)
   {
      last_entry_time = TimeCurrent();
      last_entry_bar  = iTime(_Symbol, PERIOD_M5, 0);
      if(sig.direction == 1) partial_closed_buy  = false;
      else                   partial_closed_sell = false;

      Print("OPEN ", DirStr(sig.direction),
            " lot=", DoubleToString(sig.lot, 2),
            " score=", sig.score,
            " SL=", DoubleToString(sig.sl, _Digits),
            " | ", sig.reason);
   }
   else
   {
      Print("OPEN_FAIL ", DirStr(sig.direction),
            " rc=", trade.ResultRetcode(),
            " err=", GetLastError());
   }
}

//+------------------------------------------------------------------+
//  Averaging: adds a new position when trend continues in our direction
void TryAverage(IndicatorData &d, double ask, double bid)
{
   // Average BUY
   int buy_cnt = CountPositionsByDir(1);
   if(buy_cnt > 0 && buy_cnt < MaxAveragePositions)
   {
      datetime last_add = last_avg_buy_time;
      if(TimeCurrent() - last_add >= MinSecondsBetweenAvg)
      {
         if(IsTrendConfirmed(1, d) && IsPriceAdvanced(1, ask, bid, d.atr_val))
         {
            int score = QuickScore(1, d);
            if(score >= AverageMinScore)
            {
               double lot = NormLot(LotMin + (LotMax - LotMin) * (double)(score - 1) / 4.0);
               double sl  = CalcSmartSL(1, ask, bid, d.atr_val);
               ResetLastError();
               if(trade.Buy(lot, _Symbol, ask, sl, 0.0, "M5v1 AVG BUY s=" + IntegerToString(score)))
               {
                  last_avg_buy_time = TimeCurrent();
                  last_entry_time   = TimeCurrent();
                  Print("AVG_BUY lot=", DoubleToString(lot, 2),
                        " score=", score, " SL=", DoubleToString(sl, _Digits),
                        " cnt=", buy_cnt + 1);
               }
            }
         }
      }
   }

   // Average SELL
   int sell_cnt = CountPositionsByDir(-1);
   if(sell_cnt > 0 && sell_cnt < MaxAveragePositions)
   {
      datetime last_add = last_avg_sell_time;
      if(TimeCurrent() - last_add >= MinSecondsBetweenAvg)
      {
         if(IsTrendConfirmed(-1, d) && IsPriceAdvanced(-1, ask, bid, d.atr_val))
         {
            int score = QuickScore(-1, d);
            if(score >= AverageMinScore)
            {
               double lot = NormLot(LotMin + (LotMax - LotMin) * (double)(score - 1) / 4.0);
               double sl  = CalcSmartSL(-1, ask, bid, d.atr_val);
               ResetLastError();
               if(trade.Sell(lot, _Symbol, bid, sl, 0.0, "M5v1 AVG SELL s=" + IntegerToString(score)))
               {
                  last_avg_sell_time = TimeCurrent();
                  last_entry_time    = TimeCurrent();
                  Print("AVG_SELL lot=", DoubleToString(lot, 2),
                        " score=", score, " SL=", DoubleToString(sl, _Digits),
                        " cnt=", sell_cnt + 1);
               }
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//  Trend confirmed: all EMA stack aligned + MACD histogram in direction
bool IsTrendConfirmed(int direction, IndicatorData &d)
{
   bool ema_ok = (direction == 1)
                ? d.fast_ema[1] > d.mid_ema[1] && d.mid_ema[1] > d.slow_ema[1]
                : d.fast_ema[1] < d.mid_ema[1] && d.mid_ema[1] < d.slow_ema[1];
   if(!ema_ok) return false;

   double hist = d.macd_main[1] - d.macd_sig[1];
   bool macd_ok = (direction == 1) ? hist > 0.0 : hist < 0.0;
   return macd_ok;
}

//+------------------------------------------------------------------+
//  Price has advanced enough from average open price to justify adding
bool IsPriceAdvanced(int direction, double ask, double bid, double atr_val)
{
   double avg = AvgOpenPrice(direction);
   if(avg <= 0.0) return false;

   double min_step = atr_val * AverageStepATR;

   if(direction == 1)
      return (ask - avg) >= min_step; // price moved up by at least AverageStepATR*ATR
   return (avg - bid) >= min_step;    // price moved down by at least AverageStepATR*ATR
}

//+------------------------------------------------------------------+
//  Quick score for averaging (3 checks: EMA stack, MACD, RSI)
int QuickScore(int direction, IndicatorData &d)
{
   int s = 0;
   if(IsTrendConfirmed(direction, d)) s++;

   if(direction == 1 && d.rsi[1] >= 50.0 && d.rsi[1] <= 75.0) s++;
   if(direction == -1 && d.rsi[1] <= 50.0 && d.rsi[1] >= 25.0) s++;

   bool stoch_ok = (direction == 1)
                  ? d.stoch_k[1] > d.stoch_d[1] && d.stoch_k[1] < 80.0
                  : d.stoch_k[1] < d.stoch_d[1] && d.stoch_k[1] > 20.0;
   if(stoch_ok) s++;

   return s;
}

//+------------------------------------------------------------------+
//  ManagePositions: breakeven → partial close → trailing stop → reversal exit
void ManagePositions(double ask, double bid)
{
   IndicatorData d;
   bool have_data = LoadIndicators(d);
   double atr_val = have_data ? d.atr_val : MinSL_Pips * PipSize;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!IsOurPosition(ticket)) continue;

      int    ptype      = (int)PositionGetInteger(POSITION_TYPE);
      int    direction  = (ptype == POSITION_TYPE_BUY) ? 1 : -1;
      double open_price = PositionGetDouble(POSITION_PRICE_OPEN);
      double cur_sl     = PositionGetDouble(POSITION_SL);
      double cur_tp     = PositionGetDouble(POSITION_TP);
      double volume     = PositionGetDouble(POSITION_VOLUME);

      double cur_price  = (direction == 1) ? bid : ask;
      double profit_dist = (direction == 1) ? bid - open_price : open_price - ask;

      double new_sl     = cur_sl;
      bool   do_modify  = false;

      // ── Step 1: Breakeven ─────────────────────────────────────
      double be_trigger = atr_val * BreakevenATR;
      if(profit_dist >= be_trigger)
      {
         double be_sl = (direction == 1)
                       ? NormalizeDouble(open_price + _Point, _Digits)
                       : NormalizeDouble(open_price - _Point, _Digits);
         if(IsBetterSL(direction, be_sl, new_sl))
            { new_sl = be_sl; do_modify = true; }
      }

      // ── Step 2: Partial close at TrailStartATR ─────────────────
      double trail_trigger = atr_val * TrailStartATR;
      if(PartialClosePct > 0.0 && profit_dist >= trail_trigger)
      {
         bool already = (direction == 1) ? partial_closed_buy : partial_closed_sell;
         if(!already)
         {
            double close_vol = NormLot(volume * PartialClosePct / 100.0);
            double min_lot   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
            if(close_vol >= min_lot && close_vol < volume)
            {
               if(trade.PositionClosePartial(ticket, close_vol))
               {
                  if(direction == 1) partial_closed_buy  = true;
                  else               partial_closed_sell = true;
                  Print("PARTIAL_CLOSE ticket=", ticket,
                        " vol=", DoubleToString(close_vol, 2),
                        " profitDist=", DoubleToString(profit_dist / PipSize, 1), "p");
               }
            }
         }
      }

      // ── Step 3: Trailing stop ──────────────────────────────────
      if(profit_dist >= trail_trigger && TrailDistATR > 0.0)
      {
         double trail_dist = atr_val * TrailDistATR;
         double trail_sl   = (direction == 1)
                            ? NormalizeDouble(bid - trail_dist, _Digits)
                            : NormalizeDouble(ask + trail_dist, _Digits);
         if(IsBetterSL(direction, trail_sl, new_sl))
            { new_sl = trail_sl; do_modify = true; }
      }

      // ── Step 4: Reversal exit (trend indicators flipped) ──────
      // Close when the EMA stack reverses AND MACD crosses opposite
      if(have_data && IsReversalSignal(direction, d))
      {
         double profit_pips = profit_dist / PipSize;
         if(trade.PositionClose(ticket))
            Print("REVERSAL_EXIT ticket=", ticket,
                  " profitPips=", DoubleToString(profit_pips, 1),
                  " dir=", DirStr(direction));
         continue;
      }

      if(do_modify && new_sl != cur_sl)
      {
         if(trade.PositionModify(ticket, new_sl, cur_tp))
            Print("SL_UPDATE ticket=", ticket,
                  " profitPips=", DoubleToString(profit_dist / PipSize, 1),
                  " SL=", DoubleToString(new_sl, _Digits));
      }
   }
}

//+------------------------------------------------------------------+
//  Reversal detection: EMA stack reversed AND MACD histogram crossed
bool IsReversalSignal(int direction, IndicatorData &d)
{
   bool ema_reversed;
   if(direction == 1)
      // Was bullish, now bearish stack
      ema_reversed = d.fast_ema[1] < d.mid_ema[1];
   else
      ema_reversed = d.fast_ema[1] > d.mid_ema[1];

   if(!ema_reversed) return false;

   double hist_cur  = d.macd_main[1] - d.macd_sig[1];
   double hist_prev = d.macd_main[2] - d.macd_sig[2];

   bool macd_crossed;
   if(direction == 1)
      macd_crossed = hist_cur < 0.0 && hist_prev >= 0.0; // histogram crossed below 0
   else
      macd_crossed = hist_cur > 0.0 && hist_prev <= 0.0; // histogram crossed above 0

   return macd_crossed;
}

//+------------------------------------------------------------------+
bool IsBetterSL(int direction, double new_sl, double cur_sl)
{
   if(direction == 1)
      return new_sl > cur_sl + _Point;           // BUY: higher SL is better
   return cur_sl <= 0.0 || new_sl < cur_sl - _Point; // SELL: lower SL is better
}

//+------------------------------------------------------------------+
double NormalizeStop(int direction, double sl, double ask, double bid)
{
   int stops  = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   int freeze = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   double min_dist = MathMax(MathMax(stops, freeze) + 2, 1) * _Point;
   if(direction == 1) return MathMin(sl, bid - min_dist);
   return MathMax(sl, ask + min_dist);
}

//+------------------------------------------------------------------+
//  Helper: SafeCopy shorthand
bool SC(int handle, int buffer, double &arr[], int count)
{
   if(handle == INVALID_HANDLE) return false;
   ArraySetAsSeries(arr, true);
   return CopyBuffer(handle, buffer, 0, count, arr) >= count;
}

//+------------------------------------------------------------------+
bool IsTradingSession()
{
   datetime gmt = TimeCurrent() - GMT_Offset * 3600;
   MqlDateTime t; TimeToStruct(gmt, t);
   return (t.hour >= Session_Start_H && t.hour < Session_End_H);
}

bool IsSessionEnd()
{
   datetime gmt = TimeCurrent() - GMT_Offset * 3600;
   MqlDateTime t; TimeToStruct(gmt, t);
   return (t.hour >= Session_End_H);
}

//+------------------------------------------------------------------+
void CloseAllOurPositions(string reason)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!IsOurPosition(ticket)) continue;
      double profit = PositionGetDouble(POSITION_PROFIT);
      if(trade.PositionClose(ticket))
         Print("CLOSE_", reason, " ticket=", ticket,
               " profit=", DoubleToString(profit, 2));
   }
}

//+------------------------------------------------------------------+
bool IsOurPosition(ulong ticket)
{
   if(ticket == 0) return false;
   if(PositionGetString(POSITION_SYMBOL) != _Symbol) return false;
   long magic = PositionGetInteger(POSITION_MAGIC);
   if(magic == MAGIC) return true;
   if(!ManageLegacyMagic) return false;
   return (magic == 20261010 || magic == 20261000 ||
           magic == 202604282 || magic == 202604281 || magic == 20260902);
}

//+------------------------------------------------------------------+
int CountAllPositions()
{
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(IsOurPosition(t)) n++;
   }
   return n;
}

int CountPositionsByDir(int direction)
{
   int n = 0;
   long want = (direction == 1) ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(!IsOurPosition(t)) continue;
      if(PositionGetInteger(POSITION_TYPE) == want) n++;
   }
   return n;
}

double AvgOpenPrice(int direction)
{
   double wsum = 0.0, vsum = 0.0;
   long want = (direction == 1) ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(!IsOurPosition(t)) continue;
      if(PositionGetInteger(POSITION_TYPE) != want) continue;
      double v = PositionGetDouble(POSITION_VOLUME);
      wsum += PositionGetDouble(POSITION_PRICE_OPEN) * v;
      vsum += v;
   }
   return (vsum > 0.0) ? wsum / vsum : 0.0;
}

double SidePnL(int direction)
{
   double pnl = 0.0;
   long want = (direction == 1) ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(!IsOurPosition(t)) continue;
      if(PositionGetInteger(POSITION_TYPE) == want)
         pnl += PositionGetDouble(POSITION_PROFIT);
   }
   return pnl;
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
void PrintDebug()
{
   if(!DebugPositions) return;
   if(TimeCurrent() - last_debug_time < DebugEverySeconds) return;
   last_debug_time = TimeCurrent();
   int bc = CountPositionsByDir(1), sc = CountPositionsByDir(-1);
   if(bc + sc == 0) return;
   Print("POS | BUY=", bc, " avg=", DoubleToString(AvgOpenPrice(1), _Digits),
         " PnL=", DoubleToString(SidePnL(1), 2),
         " | SELL=", sc, " avg=", DoubleToString(AvgOpenPrice(-1), _Digits),
         " PnL=", DoubleToString(SidePnL(-1), 2));
}

//+------------------------------------------------------------------+
string DirStr(int d) { return d == 1 ? "BUY" : d == -1 ? "SELL" : "NEUTRAL"; }
//+------------------------------------------------------------------+
