//+------------------------------------------------------------------+
//|                                                  GridHedgeEA.mq5 |
//|                  Bidirectional Grid + Hedge Expert Advisor v2.0   |
//|                                                                    |
//| Strategy: Places Buy Stops above and Sell Stops below an anchor   |
//| price, replenishes activated orders, uses triple-close basket      |
//| mechanism with order migration, and restarts after profit target.  |
//+------------------------------------------------------------------+
#property copyright   "Grid Hedge EA v2.0"
#property version     "2.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\OrderInfo.mqh>

//=== Input Parameters ===
input int      GridOrders         = 100;     // Number of pending orders PER SIDE
input double   GridSpacingPoints  = 50;      // Distance between each order in POINTS
input int      MagicNumber        = 777777;  // Unique EA identifier
input double   MinLot             = 0.01;    // Minimum lot size
input double   TotalProfitPercent = 1.0;     // % of account balance to trigger full close & restart
input bool     EnableMigration    = true;    // Enable/disable gap-filling migration feature

//=== Direction Constants ===
#define DIRECTION_UP   1
#define DIRECTION_DOWN 2

//=== Global Objects ===
CTrade         trade;
CPositionInfo  posInfo;
COrderInfo     ordInfo;

//=== Anchor & Session State ===
double g_anchorPrice     = 0.0;
double g_sessionLotSize  = 0.0;
bool   g_gridInitialized = false;

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
//| NormalizeDouble only ensures decimal places — this also ensures   |
//| the price is a valid multiple of SYMBOL_TRADE_TICK_SIZE.          |
//| Essential for Gold/XAU where tickSize=0.01 but digits=3.         |
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
   // points * tickValue/tickSize * lots * point
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
   // Don't even attempt if trading is globally disabled or EA is stopping
   if(IsStopped()) return false;
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) return false;
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))           return false;

   price = NormalizePrice(price);
   bool result = false;

   for(int retry = 0; retry <= 2; retry++)
   {
      // Abort retry loop if EA is being stopped
      if(IsStopped()) return false;

      if(orderType == ORDER_TYPE_BUY_STOP)
         result = trade.BuyStop(lots, price, _Symbol, 0, 0, ORDER_TIME_GTC, 0, "GridEA BuyStop");
      else if(orderType == ORDER_TYPE_SELL_STOP)
         result = trade.SellStop(lots, price, _Symbol, 0, 0, ORDER_TIME_GTC, 0, "GridEA SellStop");

      if(result) return true;

      uint error = trade.ResultRetcode();
      Print("PlacePendingOrder failed [attempt ", retry+1, "]: ",
            trade.ResultRetcodeDescription(), " Price=", price,
            " Type=", EnumToString(orderType));

      // Non-retryable: trading disabled by client or server
      if(error == TRADE_RETCODE_CLIENT_DISABLES_AT ||
         error == TRADE_RETCODE_SERVER_DISABLES_AT)
      {
         Print("PlacePendingOrder: AutoTrading is disabled — not retrying.");
         return false;
      }

      // Handle specific retryable errors
      if(error == TRADE_RETCODE_INVALID_STOPS || error == TRADE_RETCODE_INVALID_PRICE)
      {
         double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         if(orderType == ORDER_TYPE_BUY_STOP)
            price = NormalizePrice(ask + (g_stopLevel + 5) * g_point);
         else
            price = NormalizePrice(bid - (g_stopLevel + 5) * g_point);
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

      // Validate price vs stop level
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
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0) continue;
      if(OrderGetString(ORDER_SYMBOL)  != _Symbol)    continue;
      if(OrderGetInteger(ORDER_MAGIC)  != MagicNumber) continue;

      if(!trade.OrderDelete(ticket))
         Print("DeleteAllPendingOrders: Failed to delete #", ticket,
               " — ", trade.ResultRetcodeDescription());
      Sleep(100);
   }
}

//+------------------------------------------------------------------+
//| UTILITY: Close all remaining open positions for this EA           |
//+------------------------------------------------------------------+
void CloseAllRemainingPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL)  != _Symbol)    continue;
      if(PositionGetInteger(POSITION_MAGIC)  != MagicNumber) continue;

      if(!trade.PositionClose(ticket))
         Print("CloseAllRemainingPositions: Failed to close #", ticket,
               " — ", trade.ResultRetcodeDescription());
      Sleep(100);
   }
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

   // 3. Place Buy Stop orders ABOVE anchor
   for(int i = 1; i <= GridOrders; i++)
   {
      if(IsStopped()) break;

      double price = NormalizePrice(g_anchorPrice + halfSpread + (i * GridSpacingPoints * g_point));

      // Ensure at least stopLevel above Ask
      double minBuyStop = ask + g_stopLevel * g_point;
      if(price <= minBuyStop)
         price = NormalizePrice(minBuyStop + g_point);

      if(PlacePendingOrder(ORDER_TYPE_BUY_STOP, price, g_sessionLotSize))
         buyPlaced++;
   }

   // 4. Place Sell Stop orders BELOW anchor
   for(int i = 1; i <= GridOrders; i++)
   {
      if(IsStopped()) break;

      double price = NormalizePrice(g_anchorPrice - halfSpread - (i * GridSpacingPoints * g_point));

      // Ensure at least stopLevel below Bid
      double minSellStop = bid - g_stopLevel * g_point;
      if(price >= minSellStop)
         price = NormalizePrice(minSellStop - g_point);

      if(PlacePendingOrder(ORDER_TYPE_SELL_STOP, price, g_sessionLotSize))
         sellPlaced++;
   }

   // Only declare initialized if at least 1 order was placed on each side
   if(buyPlaced > 0 || sellPlaced > 0)
   {
      g_gridInitialized = true;
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

   // Rate-limit: place at most this many new orders per tick to avoid
   // log spam and CPU overload when many orders activate simultaneously.
   const int MAX_REPLENISH_PER_TICK = 5;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // --- Replenish Buy Stops ---
   int missingBuys = GridOrders - buyStopCount;
   if(missingBuys > 0)
   {
      double highestBuyStop = 0.0;
      if(buyStopCount > 0)
         highestBuyStop = buyStopOrders[buyStopCount - 1].price; // sorted ascending, last = highest
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
         lowestSellStop = sellStopOrders[0].price; // sorted ascending, first = lowest
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
//|                                                                    |
//| Scenario A (price rising): lowestSell + lowest2Buys               |
//| Scenario B (price falling): highestBuy + highest2Sells            |
//|                                                                    |
//| Migration happens BEFORE closing to capture exact prices.          |
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
         // Farthest sell stops = lowest prices (index 0, 1, 2)
         if(sellStopCount >= 3)
         {
            ModifyPendingOrder(sellStopOrders[0].ticket, closedPrice1);
            ModifyPendingOrder(sellStopOrders[1].ticket, closedPrice2);
            ModifyPendingOrder(sellStopOrders[2].ticket, closedPrice3);
         }

         // === Execute Closes ===
         // 1. CloseBy: most profitable Buy vs losing Sell (saves spread)
         if(!trade.PositionCloseBy(closeByBuyTicket, loserSell.ticket))
            Print("TryBasketClose A: PositionCloseBy failed — ",
                  trade.ResultRetcodeDescription());
         Sleep(200);

         // 2. Normal close: the other Buy
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
         // Record the 3 closing prices BEFORE anything else
         double closedPrice1 = loserBuy.price;
         double closedPrice2 = winnerSell1.price;
         double closedPrice3 = winnerSell2.price;

         // Determine which Sell is MORE profitable for CloseBy
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
         // Farthest buy stops = highest prices (last 3 indices)
         if(buyStopCount >= 3)
         {
            ModifyPendingOrder(buyStopOrders[buyStopCount - 1].ticket, closedPrice1);
            ModifyPendingOrder(buyStopOrders[buyStopCount - 2].ticket, closedPrice2);
            ModifyPendingOrder(buyStopOrders[buyStopCount - 3].ticket, closedPrice3);
         }

         // === Execute Closes ===
         // 1. CloseBy: most profitable Sell vs losing Buy
         if(!trade.PositionCloseBy(closeBySellTicket, loserBuy.ticket))
            Print("TryBasketClose B: PositionCloseBy failed — ",
                  trade.ResultRetcodeDescription());
         Sleep(200);

         // 2. Normal close: the other Sell
         if(!trade.PositionClose(normalCloseSellTicket))
            Print("TryBasketClose B: PositionClose failed — ",
                  trade.ResultRetcodeDescription());

         return;
      }
   }
}

//+------------------------------------------------------------------+
//| SINGLE DIRECTION: Close individual positions at grid spacing profit|
//+------------------------------------------------------------------+
void CloseIndividualProfitable(SOrderInfo &positions[], int count,
                                double currentPrice, ENUM_POSITION_TYPE posType)
{
   // Iterate in reverse so closing doesn't affect unprocessed indices
   for(int i = count - 1; i >= 0; i--)
   {
      double profitPoints = 0.0;

      if(posType == POSITION_TYPE_BUY)
         profitPoints = (currentPrice - positions[i].price) / g_point; // currentPrice = Bid
      else
         profitPoints = (positions[i].price - currentPrice) / g_point; // currentPrice = Ask

      if(profitPoints >= GridSpacingPoints)
      {
         if(!trade.PositionClose(positions[i].ticket))
            Print("CloseIndividualProfitable: Failed to close #", positions[i].ticket,
                  " — ", trade.ResultRetcodeDescription());
         Sleep(100);
      }
   }
}

//+------------------------------------------------------------------+
//| GAP-FILLING MIGRATION: Move farthest opposite pendings into gap   |
//|                                                                    |
//| UP direction: Only BUY positions exist, move farthest Sell Stops  |
//|               to fill gap between market and lowest Buy Stop       |
//| DOWN direction: Only SELL positions exist, move farthest Buy Stops |
//|               to fill gap between market and highest Sell Stop     |
//+------------------------------------------------------------------+
void MigrateToFillGaps(int direction,
                        SOrderInfo &marketPositions[], int posCount,
                        SOrderInfo &buyStopOrders[],  int buyStopCount,
                        SOrderInfo &sellStopOrders[],  int sellStopCount)
{
   if(direction == DIRECTION_UP)
   {
      // Only BUY positions exist, price is going up
      if(sellStopCount == 0 || posCount == 0 || buyStopCount == 0) return;

      double lowestBuyPos   = marketPositions[0].price;                      // lowest buy position
      double lowestBuyStop  = buyStopOrders[0].price;                        // lowest buy stop
      double highestSellStop = sellStopOrders[sellStopCount - 1].price;      // highest sell stop

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
      if(buyStopCount == 0 || posCount == 0 || sellStopCount == 0) return;

      double highestSellPos  = marketPositions[posCount - 1].price;          // highest sell position
      double highestSellStop = sellStopOrders[sellStopCount - 1].price;      // highest sell stop
      double lowestBuyStop   = buyStopOrders[0].price;                       // lowest buy stop

      double gapBottom = MathMax(highestSellPos, highestSellStop);
      double gapTop    = lowestBuyStop;

      if(gapTop - gapBottom <= GridSpacingPoints * g_point * 2.0) return;

      int slotsAvailable = (int)MathFloor((gapTop - gapBottom) / (GridSpacingPoints * g_point)) - 1;
      if(slotsAvailable <= 0) return;

      int ordersToMove = MathMin(slotsAvailable, buyStopCount);
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      for(int i = 0; i < ordersToMove; i++)
      {
         int    idx         = buyStopCount - 1 - i;  // start from highest buy stop
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
      Sleep(500);
   }

   // === STEP 3: Delete all pending orders ===
   DeleteAllPendingOrders();
   Sleep(500);

   // === STEP 4: Close all positions via CloseBy ===
   SOrderInfo allBuys[], allSells[];
   CollectAndSortPositions(allBuys, allSells);

   int bCount = ArraySize(allBuys);
   int sCount = ArraySize(allSells);
   int pairs  = MathMin(bCount, sCount);

   for(int i = 0; i < pairs; i++)
   {
      if(!trade.PositionCloseBy(allBuys[i].ticket, allSells[i].ticket))
         Print("ExecuteFullClose: PositionCloseBy failed — ", trade.ResultRetcodeDescription());
      Sleep(200);
   }

   // Close any remaining positions that couldn't be paired
   CloseAllRemainingPositions();

   // === STEP 5: Reset state ===
   g_gridInitialized = false;
   g_anchorPrice     = 0.0;
   g_sessionLotSize  = 0.0;

   Print("=== CYCLE COMPLETE === Profit target reached. Restarting grid...");
}

//+------------------------------------------------------------------+
//| CHART DISPLAY: Update the chart comment panel                     |
//+------------------------------------------------------------------+
void UpdateChartInfo(int buyCount, int sellCount, int buyStopCount, int sellStopCount,
                     double totalProfit, double targetProfit)
{
   double balance  = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity   = AccountInfoDouble(ACCOUNT_EQUITY);
   double progress = (targetProfit > 0.0) ? (totalProfit / targetProfit * 100.0) : 0.0;

   string info = "";
   info += "╔══════════════════════════════════╗\n";
   info += "║     GRID HEDGE EA v2.0           ║\n";
   info += "╠══════════════════════════════════╣\n";
   info += "║ Anchor Price:  " + DoubleToString(g_anchorPrice,    g_digits) + "\n";
   info += "║ Session Lot:   " + DoubleToString(g_sessionLotSize, 2)        + "\n";
   info += "║ Grid Spacing:  " + IntegerToString((int)GridSpacingPoints)    + " points\n";
   info += "╠══════════════════════════════════╣\n";
   info += "║ BUY Positions:   " + IntegerToString(buyCount)     + "\n";
   info += "║ SELL Positions:  " + IntegerToString(sellCount)    + "\n";
   info += "║ Buy Stops:       " + IntegerToString(buyStopCount)  + "\n";
   info += "║ Sell Stops:      " + IntegerToString(sellStopCount) + "\n";
   info += "╠══════════════════════════════════╣\n";
   info += "║ Floating P/L:  $" + DoubleToString(totalProfit,  2) + "\n";
   info += "║ Target (" + DoubleToString(TotalProfitPercent, 1) + "%): $" + DoubleToString(targetProfit, 2) + "\n";
   info += "║ Progress:      "  + DoubleToString(progress, 1)    + "%\n";
   info += "╠══════════════════════════════════╣\n";
   info += "║ Balance: $" + DoubleToString(balance, 2) + "\n";
   info += "║ Equity:  $" + DoubleToString(equity,  2) + "\n";
   info += "║ Migration: " + (EnableMigration ? "ON" : "OFF") + "\n";
   info += "╚══════════════════════════════════╝\n";

   Comment(info);
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

   Print("GridHedgeEA: Symbol=", _Symbol,
         " Point=", g_point,
         " Digits=", g_digits,
         " TickSize=", g_tickSize,
         " StopLevel=", g_stopLevel);

   // 2. Set up CTrade
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(10);
   trade.SetTypeFilling(ORDER_FILLING_IOC);

   // 3. CRITICAL: Require hedging account
   if(AccountInfoInteger(ACCOUNT_MARGIN_MODE) != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
   {
      Alert("GridHedgeEA: This EA requires a HEDGING account! EA will not start.");
      return INIT_FAILED;
   }

   // 4. Check for existing EA orders/positions (for restart recovery)
   bool hasExisting = false;

   // Check for existing positions
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

   // Check for existing pending orders
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

      // Recover anchor price: estimate as midpoint of the grid
      // by averaging highest buy stop and lowest sell stop
      SOrderInfo buyStops[], sellStops[];
      CollectAndSortPendingOrders(buyStops, sellStops);

      double lowestSellStop = (ArraySize(sellStops) > 0) ? sellStops[0].price : 0.0;
      double highestBuyStop = (ArraySize(buyStops)  > 0) ? buyStops[ArraySize(buyStops)-1].price : 0.0;

      if(lowestSellStop > 0.0 && highestBuyStop > 0.0)
         g_anchorPrice = NormalizePrice((lowestSellStop + highestBuyStop) / 2.0);
      else
         g_anchorPrice = NormalizePrice((SymbolInfoDouble(_Symbol, SYMBOL_ASK) +
                                         SymbolInfoDouble(_Symbol, SYMBOL_BID)) / 2.0);

      Print("GridHedgeEA: Recovered — Anchor≈", g_anchorPrice, " Lot=", g_sessionLotSize);
   }
   else
   {
      InitializeGrid();
   }

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| MAIN TICK HANDLER                                                  |
//+------------------------------------------------------------------+
void OnTick()
{
   if(!g_gridInitialized) return;

   // Skip all trading logic when AutoTrading is disabled
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED)) return;

   // --- Collect positions and pending orders ---
   SOrderInfo buyPositions[], sellPositions[];
   SOrderInfo buyStopOrders[], sellStopOrders[];

   CollectAndSortPositions(buyPositions, sellPositions);
   CollectAndSortPendingOrders(buyStopOrders, sellStopOrders);

   int buyCount      = ArraySize(buyPositions);
   int sellCount     = ArraySize(sellPositions);
   int buyStopCount  = ArraySize(buyStopOrders);
   int sellStopCount = ArraySize(sellStopOrders);

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // ============================================================
   // STEP 3: Check total profit target
   // ============================================================
   double totalProfit  = CalculateTotalFloatingProfit();
   double targetProfit = AccountInfoDouble(ACCOUNT_BALANCE) * TotalProfitPercent / 100.0;

   if(totalProfit >= targetProfit && (buyCount > 0 || sellCount > 0))
   {
      ExecuteFullClose(buyPositions, sellPositions, buyCount, sellCount);
      Sleep(2000);
      InitializeGrid();
      return;
   }

   // ============================================================
   // STEP 4: Replenish pending orders (maintain GridOrders per side)
   // ============================================================
   ReplenishPendingOrders(buyStopOrders, sellStopOrders, buyStopCount, sellStopCount);

   // ============================================================
   // STEP 5: Basket close (only when BOTH directions present)
   // ============================================================
   if(buyCount > 0 && sellCount > 0)
   {
      TryBasketClose(buyPositions, sellPositions, buyCount, sellCount,
                     buyStopOrders, sellStopOrders, buyStopCount, sellStopCount);
      // After basket operation wait for next tick to reprocess
      UpdateChartInfo(buyCount, sellCount, buyStopCount, sellStopCount, totalProfit, targetProfit);
      return;
   }

   // ============================================================
   // STEP 6: Single-direction individual profit close
   // ============================================================
   if(buyCount > 0 && sellCount == 0)
      CloseIndividualProfitable(buyPositions, buyCount, bid, POSITION_TYPE_BUY);

   if(sellCount > 0 && buyCount == 0)
      CloseIndividualProfitable(sellPositions, sellCount, ask, POSITION_TYPE_SELL);

   // ============================================================
   // STEP 7: Gap-filling migration (single direction only)
   // ============================================================
   if(EnableMigration && buyCount > 0 && sellCount == 0)
      MigrateToFillGaps(DIRECTION_UP, buyPositions, buyCount,
                        buyStopOrders, buyStopCount, sellStopOrders, sellStopCount);

   if(EnableMigration && sellCount > 0 && buyCount == 0)
      MigrateToFillGaps(DIRECTION_DOWN, sellPositions, sellCount,
                        buyStopOrders, buyStopCount, sellStopOrders, sellStopCount);

   // ============================================================
   // STEP 8: Update chart display
   // ============================================================
   // Re-read totals after potential closes
   totalProfit = CalculateTotalFloatingProfit();
   UpdateChartInfo(buyCount, sellCount, buyStopCount, sellStopCount, totalProfit, targetProfit);
}

//+------------------------------------------------------------------+
//| EA DEINITIALIZATION                                               |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Comment("");  // Clear chart display
   Print("GridHedgeEA removed. Reason: ", reason,
         " — positions and orders preserved for restart.");
}
//+------------------------------------------------------------------+
