//+------------------------------------------------------------------+
//|                                                  GridHedgeEA.mq5 |
//|                  Bidirectional Grid + Hedge Expert Advisor v3.0   |
//|                                                                    |
//| Strategy: Places Buy Stops above and Sell Stops below an anchor   |
//| price, replenishes activated orders, uses triple-close basket      |
//| mechanism with order migration, gradual profit-taking when single  |
//| direction exceeds half grid, market close protection with auto     |
//| restart, and restarts after profit target.                         |
//+------------------------------------------------------------------+
#property copyright   "Grid Hedge EA v3.0"
#property version     "3.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\OrderInfo.mqh>

//=== Grid Settings ===
input int      GridOrders         = 100;     // Number of pending orders PER SIDE
input double   GridSpacingPoints  = 50;      // Distance between each order in POINTS
input int      MagicNumber        = 777777;  // Unique EA identifier

//=== Lot Size Settings ===
input double   MinLot             = 0.01;    // Minimum lot size

//=== Profit Settings ===
input double   TotalProfitPercent = 1.0;     // % of account balance to trigger full close & restart

//=== Migration Settings ===
input bool     EnableMigration    = true;    // Enable/disable gap-filling migration feature

//=== Market Close Protection ===
input bool     UseMarketCloseProtection = true;  // Enable market close protection
input int      HoursBeforeClose         = 2;     // Hours before market close to activate protection
input int      TradingStartHour         = 1;     // Hour (server time) to start new trading day

//=== Direction Constants ===
#define DIRECTION_UP   1
#define DIRECTION_DOWN 2

//=== UI Constants ===
#define BTN_CLOSE_ALL  "GridEA_CloseAll"

//=== Global Objects ===
CTrade         trade;
CPositionInfo  posInfo;
COrderInfo     ordInfo;

//=== Anchor & Session State ===
double g_anchorPrice      = 0.0;
double g_sessionLotSize   = 0.0;
bool   g_gridInitialized  = false;
bool   g_marketCloseMode  = false;     // True when in market close protection mode
bool   g_waitingForNewDay = false;     // True when everything is closed, waiting for next day

//=== Cached Symbol Properties ===
double g_point;
int    g_digits;
double g_tickSize;
double g_tickValue;
double g_minLot;
double g_maxLot;
double g_lotStep;
int    g_stopLevel;
int    g_freezeLevel;

//=== Data Structure for Position/Order Info ===
struct SOrderInfo
{
   ulong  ticket;
   double price;
   double profit;
   double lots;
   int    type;
};

//+------------------------------------------------------------------+
//| UTILITY: Normalize price to valid tick size multiple              |
//+------------------------------------------------------------------+
double NormalizePrice(double price)
{
   if(g_tickSize > 0.0)
      price = MathRound(price / g_tickSize) * g_tickSize;
   return NormalizeDouble(price, g_digits);
}

//+------------------------------------------------------------------+
//| UTILITY: Sort array of SOrderInfo by price ascending (bubble)    |
//+------------------------------------------------------------------+
void SortByPriceAscending(SOrderInfo &arr[])
{
   int n = ArraySize(arr);
   for(int i = 0; i < n - 1; i++)
   {
      for(int j = 0; j < n - 1 - i; j++)
      {
         if(arr[j].price > arr[j+1].price)
         {
            SOrderInfo temp = arr[j];
            arr[j]   = arr[j+1];
            arr[j+1] = temp;
         }
      }
   }
}

//+------------------------------------------------------------------+
//| UTILITY: Collect and sort open positions into buy/sell arrays     |
//+------------------------------------------------------------------+
void CollectAndSortPositions(SOrderInfo &buyPositions[], SOrderInfo &sellPositions[])
{
   ArrayResize(buyPositions,  0);
   ArrayResize(sellPositions, 0);

   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL)  != _Symbol)    continue;
      if(PositionGetInteger(POSITION_MAGIC)  != MagicNumber) continue;

      SOrderInfo info;
      info.ticket = ticket;
      info.price  = PositionGetDouble(POSITION_PRICE_OPEN);
      info.profit = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      info.lots   = PositionGetDouble(POSITION_VOLUME);
      info.type   = (int)PositionGetInteger(POSITION_TYPE);

      if(info.type == POSITION_TYPE_BUY)
      {
         int sz = ArraySize(buyPositions);
         ArrayResize(buyPositions, sz + 1);
         buyPositions[sz] = info;
      }
      else if(info.type == POSITION_TYPE_SELL)
      {
         int sz = ArraySize(sellPositions);
         ArrayResize(sellPositions, sz + 1);
         sellPositions[sz] = info;
      }
   }

   SortByPriceAscending(buyPositions);
   SortByPriceAscending(sellPositions);
}

//+------------------------------------------------------------------+
//| UTILITY: Collect and sort pending orders into buy/sell stop arrays|
//+------------------------------------------------------------------+
void CollectAndSortPendingOrders(SOrderInfo &buyStopOrders[], SOrderInfo &sellStopOrders[])
{
   ArrayResize(buyStopOrders,  0);
   ArrayResize(sellStopOrders, 0);

   int total = OrdersTotal();
   for(int i = 0; i < total; i++)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0) continue;
      if(OrderGetString(ORDER_SYMBOL)  != _Symbol)    continue;
      if(OrderGetInteger(ORDER_MAGIC)  != MagicNumber) continue;

      SOrderInfo info;
      info.ticket = ticket;
      info.price  = OrderGetDouble(ORDER_PRICE_OPEN);
      info.profit = 0;
      info.lots   = OrderGetDouble(ORDER_VOLUME_CURRENT);
      info.type   = (int)OrderGetInteger(ORDER_TYPE);

      if(info.type == ORDER_TYPE_BUY_STOP)
      {
         int sz = ArraySize(buyStopOrders);
         ArrayResize(buyStopOrders, sz + 1);
         buyStopOrders[sz] = info;
      }
      else if(info.type == ORDER_TYPE_SELL_STOP)
      {
         int sz = ArraySize(sellStopOrders);
         ArrayResize(sellStopOrders, sz + 1);
         sellStopOrders[sz] = info;
      }
   }

   SortByPriceAscending(buyStopOrders);
   SortByPriceAscending(sellStopOrders);
}

//+------------------------------------------------------------------+
//| UTILITY: Calculate total floating profit (all EA positions)       |
//+------------------------------------------------------------------+
double CalculateTotalFloatingProfit()
{
   double total = 0.0;
   int n = PositionsTotal();
   for(int i = 0; i < n; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL)  != _Symbol)    continue;
      if(PositionGetInteger(POSITION_MAGIC)  != MagicNumber) continue;
      total += PositionGetDouble(POSITION_PROFIT);
      total += PositionGetDouble(POSITION_SWAP);
   }
   return total;
}

//+------------------------------------------------------------------+
//| UTILITY: Convert points to account currency money                 |
//+------------------------------------------------------------------+
double PointsToMoney(double points, double lots)
{
   return points * g_tickValue / g_tickSize * lots * g_point;
}

//+------------------------------------------------------------------+
//| UTILITY: Get highest open position price for a given type         |
//+------------------------------------------------------------------+
double GetHighestPositionPrice(int posType)
{
   double highest = 0.0;
   int n = PositionsTotal();
   for(int i = 0; i < n; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL)  != _Symbol)    continue;
      if(PositionGetInteger(POSITION_MAGIC)  != MagicNumber) continue;
      if((int)PositionGetInteger(POSITION_TYPE) != posType)  continue;
      double price = PositionGetDouble(POSITION_PRICE_OPEN);
      if(price > highest) highest = price;
   }
   return highest;
}

//+------------------------------------------------------------------+
//| UTILITY: Get lowest open position price for a given type          |
//+------------------------------------------------------------------+
double GetLowestPositionPrice(int posType)
{
   double lowest = DBL_MAX;
   int n = PositionsTotal();
   for(int i = 0; i < n; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL)  != _Symbol)    continue;
      if(PositionGetInteger(POSITION_MAGIC)  != MagicNumber) continue;
      if((int)PositionGetInteger(POSITION_TYPE) != posType)  continue;
      double price = PositionGetDouble(POSITION_PRICE_OPEN);
      if(price < lowest) lowest = price;
   }
   return (lowest == DBL_MAX) ? 0.0 : lowest;
}

//+------------------------------------------------------------------+
//| UTILITY: Place a pending order with retry and error handling       |
//+------------------------------------------------------------------+
bool PlacePendingOrder(ENUM_ORDER_TYPE orderType, double price, double lots)
{
   // Don't attempt if trading is globally disabled or EA is stopping
   if(IsStopped()) return false;
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) return false;
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))           return false;
   if(!TerminalInfoInteger(TERMINAL_CONNECTED))     return false;

   price = NormalizePrice(price);
   bool result = false;

   for(int retry = 0; retry <= 2; retry++)
   {
      // Abort retry loop if EA is being stopped or connection lost
      if(IsStopped()) return false;
      if(!TerminalInfoInteger(TERMINAL_CONNECTED)) return false;

      // Validate price against FRESH market data before sending
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      int spread = (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);

      // Use effective stop level: at least the spread to avoid "too close" rejections
      int effectiveStopPts = MathMax(g_stopLevel, spread);

      if(orderType == ORDER_TYPE_BUY_STOP && price <= ask)
      {
         price = NormalizePrice(ask + effectiveStopPts * g_point);
      }
      else if(orderType == ORDER_TYPE_SELL_STOP && price >= bid)
      {
         price = NormalizePrice(bid - effectiveStopPts * g_point);
      }

      if(orderType == ORDER_TYPE_BUY_STOP)
         result = trade.BuyStop(lots, price, _Symbol, 0, 0, ORDER_TIME_GTC, 0, "GridEA BuyStop");
      else if(orderType == ORDER_TYPE_SELL_STOP)
         result = trade.SellStop(lots, price, _Symbol, 0, 0, ORDER_TIME_GTC, 0, "GridEA SellStop");

      if(result) return true;

      uint error = trade.ResultRetcode();
      Print("PlacePendingOrder failed [attempt ", retry+1, "]: ",
            trade.ResultRetcodeDescription(), " Price=", price,
            " Ask=", ask, " Bid=", bid, " Spread=", spread,
            " Type=", EnumToString(orderType));

      // Non-retryable: trading disabled or no connection
      if(error == TRADE_RETCODE_CLIENT_DISABLES_AT ||
         error == TRADE_RETCODE_SERVER_DISABLES_AT)
      {
         Print("PlacePendingOrder: AutoTrading is disabled — not retrying.");
         return false;
      }
      if(error == TRADE_RETCODE_CONNECTION || error == TRADE_RETCODE_ERROR ||
         !TerminalInfoInteger(TERMINAL_CONNECTED))
      {
         Print("PlacePendingOrder: No connection — not retrying.");
         return false;
      }

      // Handle specific retryable errors
      if(error == TRADE_RETCODE_INVALID_STOPS || error == TRADE_RETCODE_INVALID_PRICE)
      {
         ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         spread = (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
         effectiveStopPts = MathMax(g_stopLevel, spread) + 10;

         if(orderType == ORDER_TYPE_BUY_STOP)
            price = NormalizePrice(ask + effectiveStopPts * g_point);
         else
            price = NormalizePrice(bid - effectiveStopPts * g_point);
      }
      else if(error == TRADE_RETCODE_NO_MONEY)
      {
         Print("CRITICAL: Not enough money to place order!");
         return false;
      }
      else if(error == TRADE_RETCODE_TOO_MANY_REQUESTS)
      {
         Sleep(2000);
      }
      else if(error == TRADE_RETCODE_TIMEOUT)
      {
         Sleep(1000);
      }
      else if(error == TRADE_RETCODE_REQUOTE)
      {
         Sleep(300);
      }
      else if(error == TRADE_RETCODE_REJECT)
      {
         Sleep(500);
      }
      else if(error == TRADE_RETCODE_INVALID)
      {
         Print("PlacePendingOrder: Invalid request — not retrying.");
         return false;
      }

      Sleep(300);
   }

   return false;
}

//+------------------------------------------------------------------+
//| UTILITY: Modify a pending order price with retry & error handling |
//| Includes freeze level check per v3 spec                          |
//+------------------------------------------------------------------+
bool ModifyPendingOrder(ulong ticket, double newPrice)
{
   newPrice = NormalizePrice(newPrice);

   for(int retry = 0; retry <= 2; retry++)
   {
      if(!OrderSelect(ticket))
      {
         Print("ModifyPendingOrder: Cannot select order #", ticket);
         return false;
      }

      double ask     = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double bid     = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      int    ordType = (int)OrderGetInteger(ORDER_TYPE);

      // Check stop level
      if(ordType == ORDER_TYPE_BUY_STOP)
      {
         if(newPrice <= ask + g_stopLevel * g_point)
         {
            Print("ModifyPendingOrder: BuyStop price ", newPrice,
                  " too close to Ask ", ask, " — skipping.");
            return false;
         }
      }
      else if(ordType == ORDER_TYPE_SELL_STOP)
      {
         if(newPrice >= bid - g_stopLevel * g_point)
         {
            Print("ModifyPendingOrder: SellStop price ", newPrice,
                  " too close to Bid ", bid, " — skipping.");
            return false;
         }
      }

      // Check freeze level — order too close to market to modify
      double currentOrderPrice = OrderGetDouble(ORDER_PRICE_OPEN);
      if(ordType == ORDER_TYPE_BUY_STOP)
      {
         if(MathAbs(currentOrderPrice - ask) <= g_freezeLevel * g_point)
         {
            Print("ModifyPendingOrder: BuyStop #", ticket,
                  " within freeze level of Ask — skipping.");
            return false;
         }
      }
      else if(ordType == ORDER_TYPE_SELL_STOP)
      {
         if(MathAbs(currentOrderPrice - bid) <= g_freezeLevel * g_point)
         {
            Print("ModifyPendingOrder: SellStop #", ticket,
                  " within freeze level of Bid — skipping.");
            return false;
         }
      }

      bool result = trade.OrderModify(ticket, newPrice, 0, 0, ORDER_TIME_GTC, 0);
      if(result) return true;

      uint error = trade.ResultRetcode();
      Print("ModifyPendingOrder failed [attempt ", retry+1, "] ticket=", ticket,
            ": ", trade.ResultRetcodeDescription(), " NewPrice=", newPrice);

      if(error == TRADE_RETCODE_INVALID || error == TRADE_RETCODE_NO_MONEY)
         return false;
      if(error == TRADE_RETCODE_TOO_MANY_REQUESTS)
         Sleep(2000);
      else if(error == TRADE_RETCODE_TIMEOUT)
         Sleep(1000);

      Sleep(300);
   }

   return false;
}

//+------------------------------------------------------------------+
//| UTILITY: Delete all pending orders belonging to this EA           |
//+------------------------------------------------------------------+
void DeleteAllPendingOrders()
{
   trade.SetAsyncMode(true);
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0) continue;
      if(OrderGetString(ORDER_SYMBOL)  != _Symbol)    continue;
      if(OrderGetInteger(ORDER_MAGIC)  != MagicNumber) continue;

      if(!trade.OrderDelete(ticket))
         Print("DeleteAllPendingOrders: Failed to delete #", ticket,
               " — ", trade.ResultRetcodeDescription());
   }
   trade.SetAsyncMode(false);
}

//+------------------------------------------------------------------+
//| UTILITY: Close all remaining open positions for this EA           |
//+------------------------------------------------------------------+
void CloseAllRemainingPositions()
{
   trade.SetAsyncMode(true);
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL)  != _Symbol)    continue;
      if(PositionGetInteger(POSITION_MAGIC)  != MagicNumber) continue;

      if(!trade.PositionClose(ticket))
         Print("CloseAllRemainingPositions: Failed to close #", ticket,
               " — ", trade.ResultRetcodeDescription());
   }
   trade.SetAsyncMode(false);
}

//+------------------------------------------------------------------+
//| CALCULATION: Session lot size (balance / marginPerLot / 4000)    |
//+------------------------------------------------------------------+
double CalculateSessionLotSize()
{
   double balance      = AccountInfoDouble(ACCOUNT_BALANCE);
   double marginPerLot = 0.0;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(!OrderCalcMargin(ORDER_TYPE_BUY, _Symbol, 1.0, ask, marginPerLot) || marginPerLot <= 0.0)
   {
      Print("CalculateSessionLotSize: Cannot calculate margin — using MinLot.");
      return MathMax(g_minLot, MinLot);
   }

   double lotSize = balance / (marginPerLot * 4000.0);

   // Normalize to lot step
   lotSize = MathFloor(lotSize / g_lotStep) * g_lotStep;

   // Apply limits
   lotSize = MathMax(lotSize, g_minLot);
   lotSize = MathMax(lotSize, MinLot);
   lotSize = MathMin(lotSize, g_maxLot);
   lotSize = NormalizeDouble(lotSize, 2);

   return lotSize;
}

//+------------------------------------------------------------------+
//| MARKET CLOSE: Check if within protection window before close      |
//+------------------------------------------------------------------+
bool IsMarketCloseProtectionTime()
{
   if(!UseMarketCloseProtection) return false;

   datetime serverTime = TimeCurrent();
   MqlDateTime dt;
   TimeToStruct(serverTime, dt);

   // Get session close time for the current day of week
   datetime sessionStart, sessionEnd;
   bool hasSession = SymbolInfoSessionTrade(_Symbol, (ENUM_DAY_OF_WEEK)dt.day_of_week,
                                             0, sessionStart, sessionEnd);

   if(!hasSession) return false;

   // Convert session times to comparable format
   MqlDateTime dtEnd;
   TimeToStruct(sessionEnd, dtEnd);

   // Calculate minutes until close
   int currentMinutes = dt.hour * 60 + dt.min;
   int closeMinutes   = dtEnd.hour * 60 + dtEnd.min;
   int minutesUntilClose = closeMinutes - currentMinutes;

   // Handle day wrap-around
   if(minutesUntilClose < 0)
      minutesUntilClose += 24 * 60;

   // If within HoursBeforeClose hours of market close
   if(minutesUntilClose <= HoursBeforeClose * 60 && minutesUntilClose >= 0)
      return true;

   return false;
}

//+------------------------------------------------------------------+
//| MARKET CLOSE: Check if it's time to start a new trading day       |
//+------------------------------------------------------------------+
bool IsNewTradingDay()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);

   // Check if it's the start hour and market is open
   if(dt.hour == TradingStartHour)
   {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      if(ask > 0) return true;
   }

   return false;
}

//+------------------------------------------------------------------+
//| GRID INIT: Place all pending orders around the anchor price       |
//+------------------------------------------------------------------+
void InitializeGrid()
{
   // Abort immediately if trading is disabled or EA is stopping
   if(IsStopped())
   {
      Print("InitializeGrid: EA is stopping — aborting.");
      return;
   }
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED))
   {
      Print("InitializeGrid: AutoTrading is disabled — aborting. Enable AutoTrading and restart.");
      return;
   }

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // 1. Anchor price = midpoint, fixed for the cycle (tick-aligned)
   g_anchorPrice    = NormalizePrice((ask + bid) / 2.0);
   g_sessionLotSize = CalculateSessionLotSize();

   // 2. Current spread
   int    spreadPoints = (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   double halfSpread   = (spreadPoints * g_point) / 2.0;

   Print("InitializeGrid: Anchor=", g_anchorPrice,
         " Lot=", g_sessionLotSize,
         " Spread=", spreadPoints, " pts");

   int buyPlaced  = 0;
   int sellPlaced = 0;

   // 3. INTERLEAVED placement: alternate 1 Buy Stop + 1 Sell Stop per iteration
   for(int i = 1; i <= GridOrders; i++)
   {
      if(IsStopped()) break;

      // --- Place Buy Stop i ---
      ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double buyPrice = NormalizePrice(g_anchorPrice + halfSpread + (i * GridSpacingPoints * g_point));
      if(buyPrice <= ask)
         buyPrice = NormalizePrice(ask + MathMax(g_stopLevel, 1) * g_point);
      if(PlacePendingOrder(ORDER_TYPE_BUY_STOP, buyPrice, g_sessionLotSize))
         buyPlaced++;

      if(IsStopped()) break;

      // --- Place Sell Stop i ---
      bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double sellPrice = NormalizePrice(g_anchorPrice - halfSpread - (i * GridSpacingPoints * g_point));
      if(sellPrice >= bid)
      {
         int curSpread = (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
         sellPrice = NormalizePrice(bid - MathMax(g_stopLevel, curSpread) * g_point - g_point);
      }
      if(PlacePendingOrder(ORDER_TYPE_SELL_STOP, sellPrice, g_sessionLotSize))
         sellPlaced++;
   }

   // Set flags — reset all state for new cycle
   if(buyPlaced > 0 || sellPlaced > 0)
   {
      g_gridInitialized  = true;
      g_marketCloseMode  = false;
      g_waitingForNewDay = false;

      Print("=== GRID INITIALIZED === Anchor=", g_anchorPrice,
            " Lot=", g_sessionLotSize,
            " BuyStops=", buyPlaced, " SellStops=", sellPlaced);
   }
   else
   {
      Print("InitializeGrid: No orders placed (trading disabled?) — grid NOT initialized.");
   }
}

//+------------------------------------------------------------------+
//| REPLENISH: Add new pending orders at far end when one activates   |
//+------------------------------------------------------------------+
void ReplenishPendingOrders(SOrderInfo &buyStopOrders[], SOrderInfo &sellStopOrders[],
                             int buyStopCount, int sellStopCount)
{
   // Skip entirely if trading is disabled or EA is stopping
   if(IsStopped()) return;
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) return;
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))           return;

   // Rate-limit: place at most this many new orders per tick
   const int MAX_REPLENISH_PER_TICK = 5;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // --- Replenish Buy Stops ---
   int missingBuys = GridOrders - buyStopCount;
   if(missingBuys > 0)
   {
      double highestBuyStop = 0.0;
      if(buyStopCount > 0)
         highestBuyStop = buyStopOrders[buyStopCount - 1].price;
      else
         highestBuyStop = GetHighestPositionPrice(POSITION_TYPE_BUY);

      if(highestBuyStop <= 0.0)
         highestBuyStop = ask + g_stopLevel * g_point;

      int placed = 0;
      for(int i = 1; i <= missingBuys && placed < MAX_REPLENISH_PER_TICK; i++)
      {
         if(IsStopped()) return;
         double newPrice = NormalizePrice(highestBuyStop + (i * GridSpacingPoints * g_point));
         if(newPrice > ask + g_stopLevel * g_point)
         {
            if(PlacePendingOrder(ORDER_TYPE_BUY_STOP, newPrice, g_sessionLotSize))
               placed++;
         }
      }
      if(missingBuys > MAX_REPLENISH_PER_TICK)
         Print("ReplenishPendingOrders: ", missingBuys, " buy stops missing, placed ",
               placed, " this tick (rate-limited).");
   }

   // --- Replenish Sell Stops ---
   int missingSells = GridOrders - sellStopCount;
   if(missingSells > 0)
   {
      double lowestSellStop = DBL_MAX;
      if(sellStopCount > 0)
         lowestSellStop = sellStopOrders[0].price;
      else
         lowestSellStop = GetLowestPositionPrice(POSITION_TYPE_SELL);

      if(lowestSellStop == DBL_MAX || lowestSellStop <= 0.0)
         lowestSellStop = bid - g_stopLevel * g_point;

      int placed = 0;
      for(int i = 1; i <= missingSells && placed < MAX_REPLENISH_PER_TICK; i++)
      {
         if(IsStopped()) return;
         double newPrice = NormalizePrice(lowestSellStop - (i * GridSpacingPoints * g_point));
         if(newPrice < bid - g_stopLevel * g_point)
         {
            if(PlacePendingOrder(ORDER_TYPE_SELL_STOP, newPrice, g_sessionLotSize))
               placed++;
         }
      }
      if(missingSells > MAX_REPLENISH_PER_TICK)
         Print("ReplenishPendingOrders: ", missingSells, " sell stops missing, placed ",
               placed, " this tick (rate-limited).");
   }
}

//+------------------------------------------------------------------+
//| BASKET CLOSE: Triple-close mechanism (1 loser + 2 winners)        |
//+------------------------------------------------------------------+
void TryBasketClose(SOrderInfo &buyPositions[],  SOrderInfo &sellPositions[],
                    int buyCount,                 int sellCount,
                    SOrderInfo &buyStopOrders[],  SOrderInfo &sellStopOrders[],
                    int buyStopCount,             int sellStopCount)
{
   double requiredProfit = PointsToMoney(GridSpacingPoints, g_sessionLotSize);

   // =========================================================
   // SCENARIO A: Price is rising — BUYs winning, SELLs losing
   // Close: lowest SELL (loser) + lowest 2 BUYs (winners)
   // =========================================================
   if(buyCount >= 2 && sellCount >= 1)
   {
      SOrderInfo loserSell  = sellPositions[0];
      SOrderInfo winnerBuy1 = buyPositions[0];
      SOrderInfo winnerBuy2 = buyPositions[1];

      double combinedProfit = loserSell.profit + winnerBuy1.profit + winnerBuy2.profit;

      if(combinedProfit >= requiredProfit)
      {
         // Record the 3 closing prices BEFORE anything else
         double closedPrice1 = loserSell.price;
         double closedPrice2 = winnerBuy1.price;
         double closedPrice3 = winnerBuy2.price;

         // Determine which Buy is MORE profitable for CloseBy
         ulong closeByBuyTicket, normalCloseBuyTicket;
         if(winnerBuy1.profit >= winnerBuy2.profit)
         {
            closeByBuyTicket     = winnerBuy1.ticket;
            normalCloseBuyTicket = winnerBuy2.ticket;
         }
         else
         {
            closeByBuyTicket     = winnerBuy2.ticket;
            normalCloseBuyTicket = winnerBuy1.ticket;
         }

         // === MIGRATE 3 farthest SELL STOP orders BEFORE closing ===
         if(sellStopCount >= 3)
         {
            ModifyPendingOrder(sellStopOrders[0].ticket, closedPrice1);
            ModifyPendingOrder(sellStopOrders[1].ticket, closedPrice2);
            ModifyPendingOrder(sellStopOrders[2].ticket, closedPrice3);
         }

         // === Execute Closes ===
         if(!trade.PositionCloseBy(closeByBuyTicket, loserSell.ticket))
            Print("TryBasketClose A: PositionCloseBy failed — ",
                  trade.ResultRetcodeDescription());
         Sleep(200);

         if(!trade.PositionClose(normalCloseBuyTicket))
            Print("TryBasketClose A: PositionClose failed — ",
                  trade.ResultRetcodeDescription());

         return;
      }
   }

   // =========================================================
   // SCENARIO B: Price is falling — SELLs winning, BUYs losing
   // Close: highest BUY (loser) + highest 2 SELLs (winners)
   // =========================================================
   if(sellCount >= 2 && buyCount >= 1)
   {
      SOrderInfo loserBuy    = buyPositions[buyCount - 1];
      SOrderInfo winnerSell1 = sellPositions[sellCount - 1];
      SOrderInfo winnerSell2 = sellPositions[sellCount - 2];

      double combinedProfit = loserBuy.profit + winnerSell1.profit + winnerSell2.profit;

      if(combinedProfit >= requiredProfit)
      {
         double closedPrice1 = loserBuy.price;
         double closedPrice2 = winnerSell1.price;
         double closedPrice3 = winnerSell2.price;

         ulong closeBySellTicket, normalCloseSellTicket;
         if(winnerSell1.profit >= winnerSell2.profit)
         {
            closeBySellTicket     = winnerSell1.ticket;
            normalCloseSellTicket = winnerSell2.ticket;
         }
         else
         {
            closeBySellTicket     = winnerSell2.ticket;
            normalCloseSellTicket = winnerSell1.ticket;
         }

         // === MIGRATE 3 farthest BUY STOP orders BEFORE closing ===
         if(buyStopCount >= 3)
         {
            ModifyPendingOrder(buyStopOrders[buyStopCount - 1].ticket, closedPrice1);
            ModifyPendingOrder(buyStopOrders[buyStopCount - 2].ticket, closedPrice2);
            ModifyPendingOrder(buyStopOrders[buyStopCount - 3].ticket, closedPrice3);
         }

         // === Execute Closes ===
         if(!trade.PositionCloseBy(closeBySellTicket, loserBuy.ticket))
            Print("TryBasketClose B: PositionCloseBy failed — ",
                  trade.ResultRetcodeDescription());
         Sleep(200);

         if(!trade.PositionClose(normalCloseSellTicket))
            Print("TryBasketClose B: PositionClose failed — ",
                  trade.ResultRetcodeDescription());

         return;
      }
   }
}

//+------------------------------------------------------------------+
//| GRADUAL CLOSE: Close 1 most profitable when count > half grid     |
//| Migrates 1 farthest opposite pending to the closed price          |
//+------------------------------------------------------------------+
void GradualClose(SOrderInfo &positions[], int posCount, ENUM_POSITION_TYPE posType,
                  SOrderInfo &oppositeStopOrders[], int oppositeStopCount)
{
   int halfGrid = GridOrders / 2;

   // Only close if count exceeds half grid
   if(posCount <= halfGrid) return;

   // Find the most profitable position
   int mostProfitableIdx = 0;
   double maxProfit = positions[0].profit;
   for(int i = 1; i < posCount; i++)
   {
      if(positions[i].profit > maxProfit)
      {
         maxProfit = positions[i].profit;
         mostProfitableIdx = i;
      }
   }

   // Only close if it's actually profitable
   if(maxProfit <= 0) return;

   // Record the closing price BEFORE closing
   double closedPrice = positions[mostProfitableIdx].price;
   ulong closedTicket = positions[mostProfitableIdx].ticket;

   // Migrate ONE opposite pending order to the closed price
   // Take the FARTHEST opposite pending order
   if(oppositeStopCount > 0)
   {
      ulong migrateTicket;
      if(posType == POSITION_TYPE_BUY)
      {
         // Positions are BUY, opposite pending = Sell Stops
         // Farthest Sell Stop = lowest price = index 0 (sorted ascending)
         migrateTicket = oppositeStopOrders[0].ticket;
      }
      else
      {
         // Positions are SELL, opposite pending = Buy Stops
         // Farthest Buy Stop = highest price = last index (sorted ascending)
         migrateTicket = oppositeStopOrders[oppositeStopCount - 1].ticket;
      }

      ModifyPendingOrder(migrateTicket, closedPrice);
   }

   // Now close the position
   if(!trade.PositionClose(closedTicket))
      Print("GradualClose: Failed to close #", closedTicket,
            " — ", trade.ResultRetcodeDescription());

   Print("Gradual close: ticket=", closedTicket, " price=", closedPrice,
         " profit=", maxProfit, " Migrated opposite pending to same price.");
}

//+------------------------------------------------------------------+
//| GAP-FILLING MIGRATION: Move farthest opposite pendings into gap   |
//+------------------------------------------------------------------+
void MigrateToFillGaps(int direction,
                        SOrderInfo &marketPositions[], int posCount,
                        SOrderInfo &buyStopOrders[],  SOrderInfo &sellStopOrders[],
                        int buyStopCount, int sellStopCount)
{
   if(direction == DIRECTION_UP)
   {
      // Only BUY positions exist, price is going up
      if(sellStopCount == 0 || posCount == 0) return;

      double lowestBuyPos    = marketPositions[0].price;
      double lowestBuyStop   = (buyStopCount > 0) ? buyStopOrders[0].price : lowestBuyPos;
      double highestSellStop = sellStopOrders[sellStopCount - 1].price;

      double gapBottom = highestSellStop;
      double gapTop    = MathMin(lowestBuyPos, lowestBuyStop);

      // No real gap to fill
      if(gapTop - gapBottom <= GridSpacingPoints * g_point * 2.0) return;

      int slotsAvailable = (int)MathFloor((gapTop - gapBottom) / (GridSpacingPoints * g_point)) - 1;
      if(slotsAvailable <= 0) return;

      int ordersToMove = MathMin(slotsAvailable, sellStopCount);
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

      for(int i = 0; i < ordersToMove; i++)
      {
         double targetPrice = NormalizePrice(gapTop - ((i + 1) * GridSpacingPoints * g_point));

         if(targetPrice < bid - g_stopLevel * g_point)
         {
            if(MathAbs(sellStopOrders[i].price - targetPrice) > g_point)
               ModifyPendingOrder(sellStopOrders[i].ticket, targetPrice);
         }
      }
   }
   else if(direction == DIRECTION_DOWN)
   {
      // Only SELL positions exist, price is going down
      if(buyStopCount == 0 || posCount == 0) return;

      double highestSellPos  = marketPositions[posCount - 1].price;
      double highestSellStop = (sellStopCount > 0) ? sellStopOrders[sellStopCount - 1].price : highestSellPos;
      double lowestBuyStop   = buyStopOrders[0].price;

      double gapBottom = MathMax(highestSellPos, highestSellStop);
      double gapTop    = lowestBuyStop;

      if(gapTop - gapBottom <= GridSpacingPoints * g_point * 2.0) return;

      int slotsAvailable = (int)MathFloor((gapTop - gapBottom) / (GridSpacingPoints * g_point)) - 1;
      if(slotsAvailable <= 0) return;

      int ordersToMove = MathMin(slotsAvailable, buyStopCount);
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      for(int i = 0; i < ordersToMove; i++)
      {
         int    idx         = buyStopCount - 1 - i;
         double targetPrice = NormalizePrice(gapBottom + ((i + 1) * GridSpacingPoints * g_point));

         if(targetPrice > ask + g_stopLevel * g_point)
         {
            if(MathAbs(buyStopOrders[idx].price - targetPrice) > g_point)
               ModifyPendingOrder(buyStopOrders[idx].ticket, targetPrice);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| FULL CLOSE: Hedge to neutral, delete pendings, CloseBy all pairs  |
//+------------------------------------------------------------------+
void ExecuteFullClose(SOrderInfo &buyPositions[], SOrderInfo &sellPositions[],
                      int buyCount, int sellCount)
{
   Print("=== EXECUTING FULL CLOSE === Total profit target reached.");

   // === STEP 1: Calculate total lots each side ===
   double totalBuyLots  = 0.0;
   double totalSellLots = 0.0;

   for(int i = 0; i < buyCount;  i++) totalBuyLots  += buyPositions[i].lots;
   for(int i = 0; i < sellCount; i++) totalSellLots += sellPositions[i].lots;

   // === STEP 2: Hedge to neutral ===
   double diff = NormalizeDouble(MathAbs(totalBuyLots - totalSellLots), 2);
   diff = MathCeil(diff / g_lotStep) * g_lotStep;
   diff = NormalizeDouble(diff, 2);

   if(diff > 0.0)
   {
      bool hedgeResult = false;
      if(totalBuyLots > totalSellLots)
      {
         hedgeResult = trade.Sell(diff, _Symbol, 0, 0, 0, "Hedge to neutral");
         if(!hedgeResult)
            Print("ExecuteFullClose: Hedge Sell failed — ", trade.ResultRetcodeDescription());
      }
      else if(totalSellLots > totalBuyLots)
      {
         hedgeResult = trade.Buy(diff, _Symbol, 0, 0, 0, "Hedge to neutral");
         if(!hedgeResult)
            Print("ExecuteFullClose: Hedge Buy failed — ", trade.ResultRetcodeDescription());
      }
      Sleep(100);
   }

   // === STEP 3: Delete all pending orders ===
   DeleteAllPendingOrders();

   // === STEP 4: Close all positions via CloseBy (async for speed) ===
   SOrderInfo allBuys[], allSells[];
   CollectAndSortPositions(allBuys, allSells);

   int bCount = ArraySize(allBuys);
   int sCount = ArraySize(allSells);
   int pairs  = MathMin(bCount, sCount);

   trade.SetAsyncMode(true);
   for(int i = 0; i < pairs; i++)
   {
      if(!trade.PositionCloseBy(allBuys[i].ticket, allSells[i].ticket))
         Print("ExecuteFullClose: PositionCloseBy failed — ", trade.ResultRetcodeDescription());
   }
   trade.SetAsyncMode(false);

   // Close any remaining positions that couldn't be paired
   CloseAllRemainingPositions();

   // === STEP 5: Reset state ===
   g_gridInitialized = false;
   g_anchorPrice     = 0.0;
   g_sessionLotSize  = 0.0;
   g_marketCloseMode = false;

   Print("=== CYCLE COMPLETE === Profit target reached. Restarting...");
}

//+------------------------------------------------------------------+
//| CHART DISPLAY: Update the chart comment panel (v3 layout)         |
//+------------------------------------------------------------------+
void UpdateChartInfo(int buyCount, int sellCount, int buyStopCount, int sellStopCount,
                     double totalProfit, double targetProfit, string status)
{
   double balance    = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity     = AccountInfoDouble(ACCOUNT_EQUITY);
   double progress   = (targetProfit > 0.0) ? (totalProfit / targetProfit * 100.0) : 0.0;
   double drawdown   = (balance > 0.0) ? ((balance - equity) / balance * 100.0) : 0.0;

   // Count winning/losing per side
   int buyWin = 0, buyLose = 0, sellWin = 0, sellLose = 0;
   double buyWinPL = 0.0, buyLosePL = 0.0, sellWinPL = 0.0, sellLosePL = 0.0;
   int totalPositions = PositionsTotal();
   for(int i = 0; i < totalPositions; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL)  != _Symbol)    continue;
      if(PositionGetInteger(POSITION_MAGIC)  != MagicNumber) continue;
      double pnl = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      int posType = (int)PositionGetInteger(POSITION_TYPE);
      if(posType == POSITION_TYPE_BUY)
      {
         if(pnl >= 0.0) { buyWin++;  buyWinPL  += pnl; }
         else            { buyLose++; buyLosePL += pnl; }
      }
      else
      {
         if(pnl >= 0.0) { sellWin++;  sellWinPL  += pnl; }
         else            { sellLose++; sellLosePL += pnl; }
      }
   }

   string info = "";
   info += "========================================\n";
   info += "       GRID HEDGE EA v3.0\n";
   info += "========================================\n";
   info += " Status:       " + status + "\n";
   info += " Anchor Price: " + DoubleToString(g_anchorPrice, g_digits) + "\n";
   info += " Session Lot:  " + DoubleToString(g_sessionLotSize, 2) + "\n";
   info += " Grid Spacing: " + IntegerToString((int)GridSpacingPoints) + " pts\n";
   info += " Half Grid:    " + IntegerToString(GridOrders / 2) + "\n";
   info += "----------------------------------------\n";
   info += " OPEN POSITIONS\n";
   info += "   BUY:  " + IntegerToString(buyCount) + "  (+" + IntegerToString(buyWin) + " / -" + IntegerToString(buyLose) + ")\n";
   info += "   SELL: " + IntegerToString(sellCount) + "  (+" + IntegerToString(sellWin) + " / -" + IntegerToString(sellLose) + ")\n";
   info += "   BUY  P/L: $" + DoubleToString(buyWinPL + buyLosePL, 2) + "  (W:$" + DoubleToString(buyWinPL, 2) + " L:$" + DoubleToString(buyLosePL, 2) + ")\n";
   info += "   SELL P/L: $" + DoubleToString(sellWinPL + sellLosePL, 2) + "  (W:$" + DoubleToString(sellWinPL, 2) + " L:$" + DoubleToString(sellLosePL, 2) + ")\n";
   info += " PENDING ORDERS\n";
   info += "   Buy Stops:  " + IntegerToString(buyStopCount) + " / " + IntegerToString(GridOrders) + "\n";
   info += "   Sell Stops: " + IntegerToString(sellStopCount) + " / " + IntegerToString(GridOrders) + "\n";
   info += " Total: " + IntegerToString(buyCount + sellCount + buyStopCount + sellStopCount) + "\n";
   info += "----------------------------------------\n";
   info += " Floating P/L:  $" + DoubleToString(totalProfit, 2) + "\n";
   info += " Target (" + DoubleToString(TotalProfitPercent, 1) + "%): $" + DoubleToString(targetProfit, 2) + "\n";
   info += " Progress:      " + DoubleToString(progress, 1) + "%\n";
   info += "----------------------------------------\n";
   info += " Balance:  $" + DoubleToString(balance, 2) + "\n";
   info += " Equity:   $" + DoubleToString(equity, 2) + "\n";
   info += " Drawdown: " + DoubleToString(drawdown, 1) + "%\n";
   info += "----------------------------------------\n";
   info += " Migration:    " + (EnableMigration ? "ON" : "OFF") + "\n";
   info += " Market Close: " + (g_marketCloseMode ? "ACTIVE" : "Normal") + "\n";
   info += "========================================\n";

   Comment(info);
}

//+------------------------------------------------------------------+
//| UI: Create the Close All button on the chart                      |
//+------------------------------------------------------------------+
void CreateCloseAllButton()
{
   long chartID = ChartID();
   ObjectDelete(chartID, BTN_CLOSE_ALL);

   ObjectCreate(chartID, BTN_CLOSE_ALL, OBJ_BUTTON, 0, 0, 0);
   ObjectSetInteger(chartID, BTN_CLOSE_ALL, OBJPROP_CORNER,    CORNER_LEFT_LOWER);
   ObjectSetInteger(chartID, BTN_CLOSE_ALL, OBJPROP_XDISTANCE, 10);
   ObjectSetInteger(chartID, BTN_CLOSE_ALL, OBJPROP_YDISTANCE, 50);
   ObjectSetInteger(chartID, BTN_CLOSE_ALL, OBJPROP_XSIZE,     180);
   ObjectSetInteger(chartID, BTN_CLOSE_ALL, OBJPROP_YSIZE,     35);
   ObjectSetString(chartID,  BTN_CLOSE_ALL, OBJPROP_TEXT,       "CLOSE ALL & EXIT");
   ObjectSetString(chartID,  BTN_CLOSE_ALL, OBJPROP_FONT,      "Arial Bold");
   ObjectSetInteger(chartID, BTN_CLOSE_ALL, OBJPROP_FONTSIZE,   10);
   ObjectSetInteger(chartID, BTN_CLOSE_ALL, OBJPROP_COLOR,      clrWhite);
   ObjectSetInteger(chartID, BTN_CLOSE_ALL, OBJPROP_BGCOLOR,    clrRed);
   ObjectSetInteger(chartID, BTN_CLOSE_ALL, OBJPROP_BORDER_COLOR, clrDarkRed);
   ObjectSetInteger(chartID, BTN_CLOSE_ALL, OBJPROP_STATE,      false);
   ObjectSetInteger(chartID, BTN_CLOSE_ALL, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(chartID, BTN_CLOSE_ALL, OBJPROP_ZORDER,     100);
   ChartRedraw(chartID);
}

//+------------------------------------------------------------------+
//| UI: Remove the Close All button from the chart                    |
//+------------------------------------------------------------------+
void DestroyCloseAllButton()
{
   ObjectDelete(ChartID(), BTN_CLOSE_ALL);
}

//+------------------------------------------------------------------+
//| ACTION: Close everything and shut down the EA                     |
//+------------------------------------------------------------------+
void CloseAllAndExit()
{
   Print("=== CLOSE ALL & EXIT === User requested full shutdown.");

   // 1. Delete all pending orders
   DeleteAllPendingOrders();

   // 2. Close via CloseBy where possible (saves spread, async for speed)
   SOrderInfo allBuys[], allSells[];
   CollectAndSortPositions(allBuys, allSells);
   int pairs = MathMin(ArraySize(allBuys), ArraySize(allSells));
   trade.SetAsyncMode(true);
   for(int i = 0; i < pairs; i++)
   {
      trade.PositionCloseBy(allBuys[i].ticket, allSells[i].ticket);
   }
   trade.SetAsyncMode(false);

   // 3. Close any remaining positions normally (also async internally)
   CloseAllRemainingPositions();

   // 4. Reset EA state
   g_gridInitialized  = false;
   g_anchorPrice      = 0.0;
   g_sessionLotSize   = 0.0;
   g_marketCloseMode  = false;
   g_waitingForNewDay = false;

   Print("=== ALL CLOSED === EA shutdown complete.");

   // 5. Remove EA from chart
   ExpertRemove();
}

//+------------------------------------------------------------------+
//| EA INITIALIZATION                                                  |
//+------------------------------------------------------------------+
int OnInit()
{
   // 1. Cache all symbol properties
   g_point       = SymbolInfoDouble(_Symbol,  SYMBOL_POINT);
   g_digits      = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   g_tickSize    = SymbolInfoDouble(_Symbol,  SYMBOL_TRADE_TICK_SIZE);
   g_tickValue   = SymbolInfoDouble(_Symbol,  SYMBOL_TRADE_TICK_VALUE);
   g_minLot      = SymbolInfoDouble(_Symbol,  SYMBOL_VOLUME_MIN);
   g_maxLot      = SymbolInfoDouble(_Symbol,  SYMBOL_VOLUME_MAX);
   g_lotStep     = SymbolInfoDouble(_Symbol,  SYMBOL_VOLUME_STEP);
   g_stopLevel   = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   g_freezeLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);

   Print("GridHedgeEA v3.0: Symbol=", _Symbol,
         " Point=", g_point,
         " Digits=", g_digits,
         " TickSize=", g_tickSize,
         " StopLevel=", g_stopLevel,
         " FreezeLevel=", g_freezeLevel);

   // 2. Set up CTrade
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(10);

   // Auto-detect the correct filling mode from symbol properties
   int fillingMode = (int)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((fillingMode & SYMBOL_FILLING_FOK) != 0)
      trade.SetTypeFilling(ORDER_FILLING_FOK);
   else if((fillingMode & SYMBOL_FILLING_IOC) != 0)
      trade.SetTypeFilling(ORDER_FILLING_IOC);
   else
      trade.SetTypeFilling(ORDER_FILLING_RETURN);

   Print("GridHedgeEA v3.0: FillingMode=", fillingMode,
         " Using=", ((fillingMode & SYMBOL_FILLING_FOK) != 0) ? "FOK" :
                     ((fillingMode & SYMBOL_FILLING_IOC) != 0) ? "IOC" : "RETURN");

   // 3. CRITICAL: Require hedging account
   if(AccountInfoInteger(ACCOUNT_MARGIN_MODE) != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
   {
      Alert("GridHedgeEA: This EA requires a HEDGING account! EA will not start.");
      return INIT_FAILED;
   }

   // 4. Check for existing EA orders/positions (for restart recovery)
   bool hasExisting = false;

   for(int i = 0; i < PositionsTotal(); i++)
   {
      if(PositionGetTicket(i) != 0 &&
         PositionGetString(POSITION_SYMBOL) == _Symbol &&
         PositionGetInteger(POSITION_MAGIC) == MagicNumber)
      {
         hasExisting = true;
         break;
      }
   }

   if(!hasExisting)
   {
      for(int i = 0; i < OrdersTotal(); i++)
      {
         if(OrderGetTicket(i) != 0 &&
            OrderGetString(ORDER_SYMBOL) == _Symbol &&
            OrderGetInteger(ORDER_MAGIC) == MagicNumber)
         {
            hasExisting = true;
            break;
         }
      }
   }

   if(hasExisting)
   {
      Print("GridHedgeEA: Existing grid detected — recovering session.");
      g_gridInitialized = true;

      // Recover lot size from an existing order/position
      for(int i = 0; i < OrdersTotal(); i++)
      {
         ulong ticket = OrderGetTicket(i);
         if(ticket == 0) continue;
         if(OrderGetString(ORDER_SYMBOL)  != _Symbol)    continue;
         if(OrderGetInteger(ORDER_MAGIC)  != MagicNumber) continue;
         g_sessionLotSize = OrderGetDouble(ORDER_VOLUME_CURRENT);
         break;
      }
      if(g_sessionLotSize <= 0.0)
      {
         for(int i = 0; i < PositionsTotal(); i++)
         {
            ulong ticket = PositionGetTicket(i);
            if(ticket == 0) continue;
            if(PositionGetString(POSITION_SYMBOL)  != _Symbol)    continue;
            if(PositionGetInteger(POSITION_MAGIC)  != MagicNumber) continue;
            g_sessionLotSize = PositionGetDouble(POSITION_VOLUME);
            break;
         }
      }

      // Recover anchor price from grid midpoint
      SOrderInfo buyStops[], sellStops[];
      CollectAndSortPendingOrders(buyStops, sellStops);

      double lowestSellStop = (ArraySize(sellStops) > 0) ? sellStops[0].price : 0.0;
      double highestBuyStop = (ArraySize(buyStops)  > 0) ? buyStops[ArraySize(buyStops)-1].price : 0.0;

      if(lowestSellStop > 0.0 && highestBuyStop > 0.0)
         g_anchorPrice = NormalizePrice((lowestSellStop + highestBuyStop) / 2.0);
      else
         g_anchorPrice = NormalizePrice((SymbolInfoDouble(_Symbol, SYMBOL_ASK) +
                                         SymbolInfoDouble(_Symbol, SYMBOL_BID)) / 2.0);

      Print("GridHedgeEA: Recovered — Anchor=", g_anchorPrice, " Lot=", g_sessionLotSize);
   }
   else
   {
      // No existing grid — check if we should wait for new day or start immediately
      if(IsMarketCloseProtectionTime())
      {
         g_waitingForNewDay = true;
         Print("GridHedgeEA: Market close protection active — waiting for new trading day.");
      }
      else
      {
         InitializeGrid();
      }
   }

   // 5. Create the Close All button on the chart
   CreateCloseAllButton();

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| MAIN TICK HANDLER (v3 — complete rewrite)                         |
//+------------------------------------------------------------------+
void OnTick()
{
   // ============================================================
   // STEP 0: Waiting for new day (after market close protection)
   // ============================================================
   if(g_waitingForNewDay)
   {
      if(IsNewTradingDay())
      {
         g_waitingForNewDay = false;
         InitializeGrid();
      }
      return;
   }

   if(!g_gridInitialized) return;

   // Skip all trading logic when AutoTrading is disabled or no connection
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED)) return;
   if(!TerminalInfoInteger(TERMINAL_CONNECTED)) return;

   // ============================================================
   // STEP 1-2: Refresh market data, collect positions & orders
   // ============================================================
   SOrderInfo buyPositions[], sellPositions[];
   SOrderInfo buyStopOrders[], sellStopOrders[];

   CollectAndSortPositions(buyPositions, sellPositions);
   CollectAndSortPendingOrders(buyStopOrders, sellStopOrders);

   int buyCount      = ArraySize(buyPositions);
   int sellCount     = ArraySize(sellPositions);
   int buyStopCount  = ArraySize(buyStopOrders);
   int sellStopCount = ArraySize(sellStopOrders);
   int totalPositions = buyCount + sellCount;

   // ============================================================
   // STEP 3: Market Close Protection Check
   // ============================================================
   if(UseMarketCloseProtection && !g_marketCloseMode)
   {
      if(IsMarketCloseProtectionTime())
      {
         g_marketCloseMode = true;
         Print("=== MARKET CLOSE PROTECTION ACTIVATED ===");
      }
   }

   if(g_marketCloseMode)
   {
      // In market close mode: NO new orders, NO replenishment, NO migration
      // ONLY monitor floating P/L

      if(totalPositions == 0)
      {
         // No positions open — just delete pendings and wait for new day
         DeleteAllPendingOrders();
         g_gridInitialized  = false;
         g_waitingForNewDay = true;
         Print("Market close protection: No positions. Waiting for new trading day.");
         return;
      }

      double totalProfit = CalculateTotalFloatingProfit();
      if(totalProfit >= 0)
      {
         // Break-even or profit reached — close everything
         Print("Market close protection: P/L >= 0 ($", totalProfit, "). Closing all.");
         ExecuteFullClose(buyPositions, sellPositions, buyCount, sellCount);
         DeleteAllPendingOrders();
         g_gridInitialized  = false;
         g_waitingForNewDay = true;
         return;
      }

      // Still in loss — keep monitoring, do nothing else
      UpdateChartInfo(buyCount, sellCount, buyStopCount, sellStopCount,
                      totalProfit, 0, "MARKET CLOSE - Waiting for breakeven");
      return;
   }

   // ============================================================
   // STEP 4: Check total profit target
   // ============================================================
   double totalProfit  = CalculateTotalFloatingProfit();
   double balance      = AccountInfoDouble(ACCOUNT_BALANCE);
   double targetProfit = balance * TotalProfitPercent / 100.0;

   if(totalProfit >= targetProfit && totalPositions > 0)
   {
      ExecuteFullClose(buyPositions, sellPositions, buyCount, sellCount);
      Sleep(2000);
      InitializeGrid();
      return;
   }

   // ============================================================
   // STEP 5: Replenish pending orders (maintain GridOrders per side)
   // ============================================================
   ReplenishPendingOrders(buyStopOrders, sellStopOrders, buyStopCount, sellStopCount);

   // ============================================================
   // STEP 6: Basket close (only when BOTH directions present)
   // ============================================================
   if(buyCount > 0 && sellCount > 0)
   {
      // Re-collect pending orders after replenishment (they may have changed)
      CollectAndSortPendingOrders(buyStopOrders, sellStopOrders);
      buyStopCount  = ArraySize(buyStopOrders);
      sellStopCount = ArraySize(sellStopOrders);

      TryBasketClose(buyPositions, sellPositions, buyCount, sellCount,
                     buyStopOrders, sellStopOrders, buyStopCount, sellStopCount);
      // After basket operation wait for next tick to reprocess
      UpdateChartInfo(buyCount, sellCount, buyStopCount, sellStopCount, totalProfit, targetProfit, "ACTIVE");
      return;
   }

   // ============================================================
   // STEP 7: Gradual Close (single direction, count > half grid)
   // ============================================================
   if(buyCount > 0 && sellCount == 0)
   {
      int halfGrid = GridOrders / 2;
      if(buyCount > halfGrid)
         GradualClose(buyPositions, buyCount, POSITION_TYPE_BUY,
                      sellStopOrders, sellStopCount);
   }

   if(sellCount > 0 && buyCount == 0)
   {
      int halfGrid = GridOrders / 2;
      if(sellCount > halfGrid)
         GradualClose(sellPositions, sellCount, POSITION_TYPE_SELL,
                      buyStopOrders, buyStopCount);
   }

   // ============================================================
   // STEP 8: Gap-filling migration (single direction only)
   // ============================================================
   if(EnableMigration)
   {
      // Re-collect after any gradual closes
      CollectAndSortPositions(buyPositions, sellPositions);
      CollectAndSortPendingOrders(buyStopOrders, sellStopOrders);
      buyCount      = ArraySize(buyPositions);
      sellCount     = ArraySize(sellPositions);
      buyStopCount  = ArraySize(buyStopOrders);
      sellStopCount = ArraySize(sellStopOrders);

      if(buyCount > 0 && sellCount == 0)
         MigrateToFillGaps(DIRECTION_UP, buyPositions, buyCount,
                           buyStopOrders, sellStopOrders, buyStopCount, sellStopCount);

      if(sellCount > 0 && buyCount == 0)
         MigrateToFillGaps(DIRECTION_DOWN, sellPositions, sellCount,
                           buyStopOrders, sellStopOrders, buyStopCount, sellStopCount);
   }

   // ============================================================
   // STEP 9: Update chart display
   // ============================================================
   totalProfit = CalculateTotalFloatingProfit();
   UpdateChartInfo(buyCount, sellCount, buyStopCount, sellStopCount, totalProfit, targetProfit, "ACTIVE");
}

//+------------------------------------------------------------------+
//| EA DEINITIALIZATION                                               |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   DestroyCloseAllButton();
   Comment("");  // Clear chart display
   Print("GridHedgeEA v3.0 removed. Reason: ", reason,
         " — positions and orders preserved for restart.");
}

//+------------------------------------------------------------------+
//| CHART EVENT: Handle button clicks                                 |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   if(id == CHARTEVENT_OBJECT_CLICK && sparam == BTN_CLOSE_ALL)
   {
      // Reset button visual state so it doesn't stay pressed
      ObjectSetInteger(ChartID(), BTN_CLOSE_ALL, OBJPROP_STATE, false);
      ChartRedraw(ChartID());

      CloseAllAndExit();
   }
}
//+------------------------------------------------------------------+
