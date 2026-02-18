//+------------------------------------------------------------------+
//|                                                  GridHedgeEA.mq5 |
//|                  Bidirectional Grid + Hedge Expert Advisor v4.0   |
//|                                                                    |
//| Strategy: Places pending orders above and below an anchor price,  |
//| replenishes activated orders, uses triple-close basket mechanism  |
//| (profit-based selection) with order migration, range-validated    |
//| gap-filling, optional limit-order grid, market order grid, and   |
//| restarts after profit target.                                     |
//+------------------------------------------------------------------+
#property copyright   "Grid Hedge EA v4.0"
#property version     "4.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\OrderInfo.mqh>

//=== Grid Settings ===
input int      GridOrders         = 100;     // Number of pending orders PER SIDE (100 above + 100 below)
input double   GridSpacingPoints  = 50;      // Distance between each order in POINTS
input int      MagicNumber        = 777777;  // Unique EA identifier
input double   MinLot             = 0.01;    // Minimum lot size
input double   TotalProfitPercent = 1.0;     // % of account balance to trigger full close & restart
input bool     EnableMigration    = true;    // Enable/disable gap-filling migration feature

//=== Triple Close Settings ===
input bool     EnableTripleClose  = true;    // Enable/disable triple close basket mechanism

//=== Grid Order Type ===
enum ENUM_GRID_ORDER_TYPE {
   MODE_STOP_ORDERS,    // Buy Stop + Sell Stop (default)
   MODE_LIMIT_ORDERS    // Sell Limit (above) + Buy Limit (below)
};
input ENUM_GRID_ORDER_TYPE GridOrderMode = MODE_STOP_ORDERS; // Pending order type for grid

//=== Market Order Grid (Level-Based) ===
input bool     EnableMarketOrderGrid   = false;  // Enable market order grid mode
input double   MarketGridStartPrice    = 0;      // Starting reference price (0 = auto mid-price)

enum ENUM_MARKET_GRID_DIRECTION {
   MARKET_GRID_BUY_ABOVE,    // BUY above start, SELL below
   MARKET_GRID_SELL_ABOVE    // SELL above start, BUY below
};
input ENUM_MARKET_GRID_DIRECTION MarketGridAboveDir = MARKET_GRID_BUY_ABOVE; // Direction above/below start

//=== Direction Constants ===
#define DIRECTION_UP   0
#define DIRECTION_DOWN 1

//=== UI Constants ===
#define BTN_CLOSE_ALL  "GridEA_CloseAll"

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

//=== Market Order Grid State ===
double g_marketGridLevels[];         // Price levels above and below start
int    g_marketGridDirections[];     // 0 = BUY, 1 = SELL for each level
int    g_marketGridLevelCount = 0;   // Current number of active levels
double g_marketGridStartPrice = 0.0; // The starting reference price used

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
//| UTILITY: Return the pending order type placed ABOVE the anchor   |
//| Stop mode: Buy Stop (activates BUY when price rises)             |
//| Limit mode: Sell Limit (triggers SELL when price rises to level) |
//+------------------------------------------------------------------+
ENUM_ORDER_TYPE GetAbovePendingType()
{
   if(GridOrderMode == MODE_LIMIT_ORDERS)
      return ORDER_TYPE_SELL_LIMIT;
   return ORDER_TYPE_BUY_STOP;
}

//+------------------------------------------------------------------+
//| UTILITY: Return the pending order type placed BELOW the anchor   |
//| Stop mode: Sell Stop (activates SELL when price falls)           |
//| Limit mode: Buy Limit (triggers BUY when price falls to level)   |
//+------------------------------------------------------------------+
ENUM_ORDER_TYPE GetBelowPendingType()
{
   if(GridOrderMode == MODE_LIMIT_ORDERS)
      return ORDER_TYPE_BUY_LIMIT;
   return ORDER_TYPE_SELL_STOP;
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
//| UTILITY: Collect and sort pending orders into above/below arrays  |
//|                                                                    |
//| buyStopOrders  = ABOVE-anchor pending orders                      |
//|   Stop mode:  ORDER_TYPE_BUY_STOP                                 |
//|   Limit mode: ORDER_TYPE_SELL_LIMIT                               |
//|                                                                    |
//| sellStopOrders = BELOW-anchor pending orders                      |
//|   Stop mode:  ORDER_TYPE_SELL_STOP                                |
//|   Limit mode: ORDER_TYPE_BUY_LIMIT                                |
//+------------------------------------------------------------------+
void CollectAndSortPendingOrders(SOrderInfo &buyStopOrders[], SOrderInfo &sellStopOrders[])
{
   ArrayResize(buyStopOrders,  0);
   ArrayResize(sellStopOrders, 0);

   ENUM_ORDER_TYPE aboveType = GetAbovePendingType();
   ENUM_ORDER_TYPE belowType = GetBelowPendingType();

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

      if(info.type == (int)aboveType)
      {
         int sz = ArraySize(buyStopOrders);
         ArrayResize(buyStopOrders, sz + 1);
         buyStopOrders[sz] = info;
      }
      else if(info.type == (int)belowType)
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
      else if(orderType == ORDER_TYPE_SELL_LIMIT && price <= ask)
      {
         // Sell Limit must be ABOVE current Ask
         price = NormalizePrice(ask + effectiveStopPts * g_point);
      }
      else if(orderType == ORDER_TYPE_BUY_LIMIT && price >= bid)
      {
         // Buy Limit must be BELOW current Bid
         price = NormalizePrice(bid - effectiveStopPts * g_point);
      }

      if(orderType == ORDER_TYPE_BUY_STOP)
         result = trade.BuyStop(lots, price, _Symbol, 0, 0, ORDER_TIME_GTC, 0, "GridEA BuyStop");
      else if(orderType == ORDER_TYPE_SELL_STOP)
         result = trade.SellStop(lots, price, _Symbol, 0, 0, ORDER_TIME_GTC, 0, "GridEA SellStop");
      else if(orderType == ORDER_TYPE_SELL_LIMIT)
         result = trade.SellLimit(lots, price, _Symbol, 0, 0, ORDER_TIME_GTC, 0, "GridEA SellLimit");
      else if(orderType == ORDER_TYPE_BUY_LIMIT)
         result = trade.BuyLimit(lots, price, _Symbol, 0, 0, ORDER_TIME_GTC, 0, "GridEA BuyLimit");

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
         // Refresh prices and place further from market (use spread as safe distance)
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

      // Validate price vs stop level for all 4 order types
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
      else if(ordType == ORDER_TYPE_SELL_LIMIT)
      {
         // Sell Limit must remain ABOVE Ask
         if(newPrice <= ask + g_stopLevel * g_point)
         {
            Print("ModifyPendingOrder: SellLimit price ", newPrice,
                  " too close to Ask ", ask, " — skipping.");
            return false;
         }
      }
      else if(ordType == ORDER_TYPE_BUY_LIMIT)
      {
         // Buy Limit must remain BELOW Bid
         if(newPrice >= bid - g_stopLevel * g_point)
         {
            Print("ModifyPendingOrder: BuyLimit price ", newPrice,
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

   // 3. INTERLEAVED placement: alternate above + below per iteration
   //    This builds both sides simultaneously so fewer orders activate during placement.
   ENUM_ORDER_TYPE aboveType = GetAbovePendingType();
   ENUM_ORDER_TYPE belowType = GetBelowPendingType();

   for(int i = 1; i <= GridOrders; i++)
   {
      if(IsStopped()) break;

      // --- Place above-anchor order i ---
      ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double abovePrice = NormalizePrice(g_anchorPrice + halfSpread + (i * GridSpacingPoints * g_point));
      if(aboveType == ORDER_TYPE_BUY_STOP && abovePrice <= ask)
         abovePrice = NormalizePrice(ask + MathMax(g_stopLevel, 1) * g_point);
      else if(aboveType == ORDER_TYPE_SELL_LIMIT && abovePrice <= ask)
         abovePrice = NormalizePrice(ask + MathMax(g_stopLevel, 1) * g_point);
      if(PlacePendingOrder(aboveType, abovePrice, g_sessionLotSize))
         buyPlaced++;

      if(IsStopped()) break;

      // --- Place below-anchor order i ---
      bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double belowPrice = NormalizePrice(g_anchorPrice - halfSpread - (i * GridSpacingPoints * g_point));
      if(belowType == ORDER_TYPE_SELL_STOP && belowPrice >= bid)
      {
         int curSpread = (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
         belowPrice = NormalizePrice(bid - MathMax(g_stopLevel, curSpread) * g_point - g_point);
      }
      else if(belowType == ORDER_TYPE_BUY_LIMIT && belowPrice >= bid)
      {
         int curSpread = (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
         belowPrice = NormalizePrice(bid - MathMax(g_stopLevel, curSpread) * g_point - g_point);
      }
      if(PlacePendingOrder(belowType, belowPrice, g_sessionLotSize))
         sellPlaced++;
   }

   // Only declare initialized if at least 1 order was placed on each side
   if(buyPlaced > 0 || sellPlaced > 0)
   {
      g_gridInitialized = true;
      Print("=== GRID INITIALIZED === Anchor=", g_anchorPrice,
            " Lot=", g_sessionLotSize,
            " AbovePending=", buyPlaced, " BelowPending=", sellPlaced,
            " Mode=", EnumToString(GridOrderMode));

      // Initialize market order grid levels if enabled
      if(EnableMarketOrderGrid)
         InitializeMarketGridLevels();
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

   ENUM_ORDER_TYPE aboveType = GetAbovePendingType();
   ENUM_ORDER_TYPE belowType = GetBelowPendingType();

   // --- Replenish above-anchor pending orders ---
   int missingBuys = GridOrders - buyStopCount;
   if(missingBuys > 0)
   {
      double highestAbove = 0.0;
      if(buyStopCount > 0)
         highestAbove = buyStopOrders[buyStopCount - 1].price; // sorted ascending, last = highest
      else
         highestAbove = GetHighestPositionPrice(POSITION_TYPE_BUY);

      if(highestAbove <= 0.0)
         highestAbove = ask + g_stopLevel * g_point;

      int placed = 0;
      for(int i = 1; i <= missingBuys && placed < MAX_REPLENISH_PER_TICK; i++)
      {
         if(IsStopped()) return;
         double newPrice = NormalizePrice(highestAbove + (i * GridSpacingPoints * g_point));
         if(newPrice > ask + g_stopLevel * g_point)
         {
            if(PlacePendingOrder(aboveType, newPrice, g_sessionLotSize))
               placed++;
         }
      }
      if(missingBuys > MAX_REPLENISH_PER_TICK)
         Print("ReplenishPendingOrders: ", missingBuys, " above-anchor pending missing, placed ",
               placed, " this tick (rate-limited).");
   }

   // --- Replenish below-anchor pending orders ---
   int missingSells = GridOrders - sellStopCount;
   if(missingSells > 0)
   {
      double lowestBelow = DBL_MAX;
      if(sellStopCount > 0)
         lowestBelow = sellStopOrders[0].price; // sorted ascending, first = lowest
      else
         lowestBelow = GetLowestPositionPrice(POSITION_TYPE_SELL);

      if(lowestBelow == DBL_MAX || lowestBelow <= 0.0)
         lowestBelow = bid - g_stopLevel * g_point;

      int placed = 0;
      for(int i = 1; i <= missingSells && placed < MAX_REPLENISH_PER_TICK; i++)
      {
         if(IsStopped()) return;
         double newPrice = NormalizePrice(lowestBelow - (i * GridSpacingPoints * g_point));
         if(newPrice < bid - g_stopLevel * g_point)
         {
            if(PlacePendingOrder(belowType, newPrice, g_sessionLotSize))
               placed++;
         }
      }
      if(missingSells > MAX_REPLENISH_PER_TICK)
         Print("ReplenishPendingOrders: ", missingSells, " below-anchor pending missing, placed ",
               placed, " this tick (rate-limited).");
   }
}

//+------------------------------------------------------------------+
//| BASKET CLOSE: Triple-close mechanism (1 largest loser + 2 largest|
//| winners by profit magnitude, from opposite direction)            |
//|                                                                    |
//| Selection logic (v4):                                             |
//|  - Loser = position with most negative profit (any direction)     |
//|  - Winners = 2 positions with highest positive profit, opposite   |
//|    type of loser                                                   |
//|  - Condition: winners combined profit > |loser loss| (net +ve)   |
//|  - Migration happens BEFORE closing                               |
//|  - Guarded by EnableTripleClose input                             |
//+------------------------------------------------------------------+
void TryBasketClose(SOrderInfo &buyPositions[],  SOrderInfo &sellPositions[],
                    int buyCount,                 int sellCount,
                    SOrderInfo &buyStopOrders[],  SOrderInfo &sellStopOrders[],
                    int buyStopCount,             int sellStopCount)
{
   // Guard: skip if triple close is disabled
   if(!EnableTripleClose) return;

   // ===================================================================
   // STEP 1: Merge ALL positions into one combined array
   // ===================================================================
   int totalPos = buyCount + sellCount;
   if(totalPos < 3) return; // Need at least 1 loser + 2 winners

   SOrderInfo allPositions[];
   ArrayResize(allPositions, totalPos);
   int idx = 0;
   for(int i = 0; i < buyCount;  i++) { allPositions[idx] = buyPositions[i];  idx++; }
   for(int i = 0; i < sellCount; i++) { allPositions[idx] = sellPositions[i]; idx++; }

   // ===================================================================
   // STEP 2: Find the LARGEST LOSER (most negative profit)
   // ===================================================================
   int    loserIdx  = -1;
   double worstLoss = 0.0;
   for(int i = 0; i < totalPos; i++)
   {
      if(allPositions[i].profit < worstLoss)
      {
         worstLoss = allPositions[i].profit;
         loserIdx  = i;
      }
   }
   if(loserIdx == -1) return; // No losing position found

   SOrderInfo loser    = allPositions[loserIdx];
   int        loserType  = loser.type; // POSITION_TYPE_BUY or POSITION_TYPE_SELL
   int        winnerType = (loserType == POSITION_TYPE_BUY) ? POSITION_TYPE_SELL : POSITION_TYPE_BUY;

   // ===================================================================
   // STEP 3: Find the 2 LARGEST WINNERS (highest positive profit)
   //         They must be the OPPOSITE type of the loser
   // ===================================================================
   int    winner1Idx   = -1, winner2Idx   = -1;
   double bestProfit1  =  0.0, bestProfit2  =  0.0;

   for(int i = 0; i < totalPos; i++)
   {
      if(i == loserIdx)                               continue;
      if(allPositions[i].type   != winnerType)        continue;
      if(allPositions[i].profit <= 0.0)               continue; // must be in profit

      if(allPositions[i].profit > bestProfit1)
      {
         bestProfit2 = bestProfit1; winner2Idx = winner1Idx;
         bestProfit1 = allPositions[i].profit; winner1Idx = i;
      }
      else if(allPositions[i].profit > bestProfit2)
      {
         bestProfit2 = allPositions[i].profit; winner2Idx = i;
      }
   }

   // Need exactly 2 winners
   if(winner1Idx == -1 || winner2Idx == -1) return;

   SOrderInfo winner1 = allPositions[winner1Idx];
   SOrderInfo winner2 = allPositions[winner2Idx];

   // ===================================================================
   // STEP 4: Condition — combined winners profit must exceed |loser loss|
   // ===================================================================
   double winnersProfit = winner1.profit + winner2.profit;
   double loserLoss     = MathAbs(loser.profit);

   if(winnersProfit <= loserLoss) return; // Not profitable enough (net would be negative)

   // ===================================================================
   // STEP 5: Record the 3 closing prices BEFORE closing
   // ===================================================================
   double closedPrice1 = loser.price;
   double closedPrice2 = winner1.price;
   double closedPrice3 = winner2.price;

   // ===================================================================
   // STEP 6: Migrate 3 farthest pending orders of the LOSER'S TYPE
   //         to the 3 closed position prices (BEFORE closing)
   // ===================================================================
   if(loserType == POSITION_TYPE_BUY)
   {
      // Loser is BUY → migrate 3 farthest above-anchor (BUY STOP or BUY LIMIT) orders
      // buyStopOrders sorted ASCENDING: last indices = highest = farthest
      if(buyStopCount >= 3)
      {
         ModifyPendingOrder(buyStopOrders[buyStopCount - 1].ticket, closedPrice1);
         ModifyPendingOrder(buyStopOrders[buyStopCount - 2].ticket, closedPrice2);
         ModifyPendingOrder(buyStopOrders[buyStopCount - 3].ticket, closedPrice3);
      }
   }
   else
   {
      // Loser is SELL → migrate 3 farthest below-anchor (SELL STOP or SELL LIMIT) orders
      // sellStopOrders sorted ASCENDING: index 0 = lowest = farthest when price is up
      if(sellStopCount >= 3)
      {
         ModifyPendingOrder(sellStopOrders[0].ticket, closedPrice1);
         ModifyPendingOrder(sellStopOrders[1].ticket, closedPrice2);
         ModifyPendingOrder(sellStopOrders[2].ticket, closedPrice3);
      }
   }

   // ===================================================================
   // STEP 7: Execute closes
   //         CloseBy: MOST profitable winner vs loser (saves spread)
   //         Normal close: other winner
   // ===================================================================
   ulong closeByWinnerTicket, normalCloseWinnerTicket;
   if(winner1.profit >= winner2.profit)
   {
      closeByWinnerTicket    = winner1.ticket;
      normalCloseWinnerTicket = winner2.ticket;
   }
   else
   {
      closeByWinnerTicket    = winner2.ticket;
      normalCloseWinnerTicket = winner1.ticket;
   }

   if(!trade.PositionCloseBy(closeByWinnerTicket, loser.ticket))
      Print("TryBasketClose: PositionCloseBy failed — ", trade.ResultRetcodeDescription());
   Sleep(200);

   if(!trade.PositionClose(normalCloseWinnerTicket))
      Print("TryBasketClose: PositionClose failed — ", trade.ResultRetcodeDescription());
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
//| UP direction: Only BUY positions exist, move farthest below-      |
//|               anchor pendings to fill gap (with range validation) |
//| DOWN direction: Only SELL positions exist, move farthest above-   |
//|               anchor pendings to fill gap (with range validation) |
//|                                                                    |
//| RANGE VALIDATION (v4): target price must fall BETWEEN:            |
//|  - highest SELL position or Sell Stop price (lower boundary)      |
//|  - lowest BUY position or Buy Stop price   (upper boundary)       |
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

      double lowestBuyPos    = marketPositions[0].price;                     // lowest buy position
      double lowestBuyStop   = buyStopOrders[0].price;                       // lowest buy stop
      double highestSellStop = sellStopOrders[sellStopCount - 1].price;      // highest sell stop

      // Define valid range boundaries
      double rangeUpperBound = MathMin(lowestBuyPos, lowestBuyStop); // lowest BUY or Buy Stop
      double rangeLowerBound = highestSellStop;                       // highest Sell Stop

      double gapTop    = rangeUpperBound;
      double gapBottom = rangeLowerBound;

      // No real gap to fill
      if(gapTop - gapBottom <= GridSpacingPoints * g_point * 2.0) return;

      int slotsAvailable = (int)MathFloor((gapTop - gapBottom) / (GridSpacingPoints * g_point)) - 1;
      if(slotsAvailable <= 0) return;

      int ordersToMove = MathMin(slotsAvailable, sellStopCount);
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

      for(int i = 0; i < ordersToMove; i++)
      {
         double targetPrice = NormalizePrice(gapTop - ((i + 1) * GridSpacingPoints * g_point));

         // RANGE CHECK: ensure target is within valid range
         if(targetPrice <= rangeLowerBound || targetPrice >= rangeUpperBound) continue;

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

      // Define valid range boundaries
      double rangeLowerBound = MathMax(highestSellPos, highestSellStop); // highest SELL or Sell Stop
      double rangeUpperBound = lowestBuyStop;                            // lowest Buy Stop

      double gapBottom = rangeLowerBound;
      double gapTop    = rangeUpperBound;

      if(gapTop - gapBottom <= GridSpacingPoints * g_point * 2.0) return;

      int slotsAvailable = (int)MathFloor((gapTop - gapBottom) / (GridSpacingPoints * g_point)) - 1;
      if(slotsAvailable <= 0) return;

      int ordersToMove = MathMin(slotsAvailable, buyStopCount);
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      for(int i = 0; i < ordersToMove; i++)
      {
         int    idx         = buyStopCount - 1 - i;  // start from highest buy stop
         double targetPrice = NormalizePrice(gapBottom + ((i + 1) * GridSpacingPoints * g_point));

         // RANGE CHECK: ensure target is within valid range
         if(targetPrice <= rangeLowerBound || targetPrice >= rangeUpperBound) continue;

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
   g_gridInitialized     = false;
   g_anchorPrice         = 0.0;
   g_sessionLotSize      = 0.0;
   g_marketGridLevelCount = 0;
   g_marketGridStartPrice = 0.0;
   ArrayResize(g_marketGridLevels,     0);
   ArrayResize(g_marketGridDirections, 0);

   Print("=== CYCLE COMPLETE === Profit target reached. Restarting grid...");
}

//+------------------------------------------------------------------+
//| MARKET GRID: Initialize price-level arrays above and below start  |
//+------------------------------------------------------------------+
void InitializeMarketGridLevels()
{
   // Determine starting price
   if(MarketGridStartPrice > 0)
      g_marketGridStartPrice = NormalizeDouble(MarketGridStartPrice, g_digits);
   else
   {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      g_marketGridStartPrice = NormalizeDouble((ask + bid) / 2.0, g_digits);
   }

   double spacing   = GridSpacingPoints * g_point;
   int totalLevels  = GridOrders * 2; // GridOrders above + GridOrders below

   ArrayResize(g_marketGridLevels,     totalLevels);
   ArrayResize(g_marketGridDirections, totalLevels);
   g_marketGridLevelCount = totalLevels;

   int idx = 0;

   // Levels ABOVE starting price
   for(int i = 1; i <= GridOrders; i++)
   {
      double level = NormalizeDouble(g_marketGridStartPrice + (i * spacing), g_digits);
      g_marketGridLevels[idx]     = level;
      g_marketGridDirections[idx] = (MarketGridAboveDir == MARKET_GRID_BUY_ABOVE) ? 0 : 1; // 0=BUY, 1=SELL
      idx++;
   }

   // Levels BELOW starting price
   for(int i = 1; i <= GridOrders; i++)
   {
      double level = NormalizeDouble(g_marketGridStartPrice - (i * spacing), g_digits);
      g_marketGridLevels[idx]     = level;
      g_marketGridDirections[idx] = (MarketGridAboveDir == MARKET_GRID_BUY_ABOVE) ? 1 : 0; // opposite of above
      idx++;
   }

   Print("=== MARKET GRID INITIALIZED === Start=", g_marketGridStartPrice,
         " Levels=", g_marketGridLevelCount, " Spacing=", GridSpacingPoints, "pts");
}

//+------------------------------------------------------------------+
//| MARKET GRID: Remove a triggered level from the array (one-shot)  |
//+------------------------------------------------------------------+
void RemoveMarketGridLevel(int index)
{
   if(index < 0 || index >= g_marketGridLevelCount) return;

   // Shift all elements after 'index' one position to the left
   for(int j = index; j < g_marketGridLevelCount - 1; j++)
   {
      g_marketGridLevels[j]     = g_marketGridLevels[j + 1];
      g_marketGridDirections[j] = g_marketGridDirections[j + 1];
   }

   g_marketGridLevelCount--;
   ArrayResize(g_marketGridLevels,     g_marketGridLevelCount);
   ArrayResize(g_marketGridDirections, g_marketGridLevelCount);
}

//+------------------------------------------------------------------+
//| MARKET GRID: Check price crossings and open market orders        |
//+------------------------------------------------------------------+
void ProcessMarketGridLevels()
{
   if(!EnableMarketOrderGrid)          return;
   if(g_marketGridLevelCount <= 0)     return;
   if(IsStopped())                     return;
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) return;
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))           return;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   // Scan in reverse for safe removal during iteration
   for(int i = g_marketGridLevelCount - 1; i >= 0; i--)
   {
      double level    = g_marketGridLevels[i];
      bool triggered  = false;

      // Levels ABOVE start: triggered when Ask >= level
      // Levels BELOW start: triggered when Bid <= level
      if(level > g_marketGridStartPrice)
      {
         if(ask >= level) triggered = true;
      }
      else
      {
         if(bid <= level) triggered = true;
      }

      if(triggered)
      {
         if(g_marketGridDirections[i] == 0) // BUY
         {
            if(!trade.Buy(g_sessionLotSize, _Symbol, 0, 0, 0,
                          "MarketGrid BUY at " + DoubleToString(level, g_digits)))
               Print("MarketGrid BUY failed — ", trade.ResultRetcodeDescription());
            else
               Print("MarketGrid: BUY triggered at level ", level);
         }
         else // SELL
         {
            if(!trade.Sell(g_sessionLotSize, _Symbol, 0, 0, 0,
                           "MarketGrid SELL at " + DoubleToString(level, g_digits)))
               Print("MarketGrid SELL failed — ", trade.ResultRetcodeDescription());
            else
               Print("MarketGrid: SELL triggered at level ", level);
         }

         RemoveMarketGridLevel(i); // One-shot: remove level after triggering
      }
   }
}

//+------------------------------------------------------------------+
//| CHART DISPLAY: Update the chart comment panel                     |
//+------------------------------------------------------------------+
void UpdateChartInfo(int buyCount, int sellCount, int buyStopCount, int sellStopCount,
                     double totalProfit, double targetProfit)
{
   double balance    = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity     = AccountInfoDouble(ACCOUNT_EQUITY);
   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double marginUsed = AccountInfoDouble(ACCOUNT_MARGIN);
   double marginLvl  = AccountInfoDouble(ACCOUNT_MARGIN_LEVEL);
   double progress   = (targetProfit > 0.0) ? (totalProfit / targetProfit * 100.0) : 0.0;

   int spread = (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   bool connected = (bool)TerminalInfoInteger(TERMINAL_CONNECTED);

   // Count winning/losing positions and their totals
   int winCount = 0, loseCount = 0;
   double winTotal = 0.0, loseTotal = 0.0;
   int totalPositions = PositionsTotal();
   for(int i = 0; i < totalPositions; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL)  != _Symbol)    continue;
      if(PositionGetInteger(POSITION_MAGIC)  != MagicNumber) continue;
      double pnl = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      if(pnl >= 0.0)  { winCount++;  winTotal  += pnl; }
      else             { loseCount++; loseTotal += pnl; }
   }

   string info = "";
   info += "========================================\n";
   info += "       GRID HEDGE EA v2.0\n";
   info += "========================================\n";
   info += " Anchor:     " + DoubleToString(g_anchorPrice, g_digits) + "\n";
   info += " Session Lot: " + DoubleToString(g_sessionLotSize, 2) + "\n";
   info += " Spacing:    " + IntegerToString((int)GridSpacingPoints) + " pts\n";
   info += "----------------------------------------\n";
   info += " POSITIONS\n";
   info += "   BUY:  " + IntegerToString(buyCount) + "    SELL: " + IntegerToString(sellCount) + "\n";
   info += "   Total: " + IntegerToString(buyCount + sellCount) + "\n";
   info += " PENDING\n";
   info += "   Buy Stops:  " + IntegerToString(buyStopCount) + " / " + IntegerToString(GridOrders) + "\n";
   info += "   Sell Stops: " + IntegerToString(sellStopCount) + " / " + IntegerToString(GridOrders) + "\n";
   info += "----------------------------------------\n";
   info += " TRADE STATS\n";
   info += "   Winning:  " + IntegerToString(winCount) + "  ($" + DoubleToString(winTotal, 2) + ")\n";
   info += "   Losing:   " + IntegerToString(loseCount) + "  ($" + DoubleToString(loseTotal, 2) + ")\n";
   info += "   Net P/L:  $" + DoubleToString(totalProfit, 2) + "\n";
   info += "----------------------------------------\n";
   info += " PROFIT TARGET\n";
   info += "   Target (" + DoubleToString(TotalProfitPercent, 1) + "%): $" + DoubleToString(targetProfit, 2) + "\n";
   info += "   Progress:    " + DoubleToString(progress, 1) + "%\n";
   info += "----------------------------------------\n";
   info += " ACCOUNT\n";
   info += "   Balance:     $" + DoubleToString(balance, 2) + "\n";
   info += "   Equity:      $" + DoubleToString(equity, 2) + "\n";
   info += "   Free Margin: $" + DoubleToString(freeMargin, 2) + "\n";
   info += "   Margin Used: $" + DoubleToString(marginUsed, 2) + "\n";
   info += "   Margin Lvl:  " + (marginUsed > 0 ? DoubleToString(marginLvl, 1) + "%" : "---") + "\n";
   info += "----------------------------------------\n";
   info += " MARKET\n";
   info += "   Bid: " + DoubleToString(bid, g_digits) + "  Ask: " + DoubleToString(ask, g_digits) + "\n";
   info += "   Spread: " + IntegerToString(spread) + " pts\n";
   info += "   Migration:   " + (EnableMigration ? "ON" : "OFF") + "\n";
   info += "   TripleClose: " + (EnableTripleClose ? "ON" : "OFF") + "\n";
   info += "   GridMode:    " + EnumToString(GridOrderMode) + "\n";
   info += "   MktGrid:     " + (EnableMarketOrderGrid ? "ON (" + IntegerToString(g_marketGridLevelCount) + " levels)" : "OFF") + "\n";
   info += "   Connection:  " + (connected ? "OK" : "LOST") + "\n";
   info += "========================================\n";

   Comment(info);
}

//+------------------------------------------------------------------+
//| UI: Create the Close All button on the chart                      |
//+------------------------------------------------------------------+
void CreateCloseAllButton()
{
   long chartID = ChartID();
   // Delete if it already exists (e.g., on re-init)
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
   Sleep(500);

   // 2. Close via CloseBy where possible (saves spread)
   SOrderInfo allBuys[], allSells[];
   CollectAndSortPositions(allBuys, allSells);
   int pairs = MathMin(ArraySize(allBuys), ArraySize(allSells));
   for(int i = 0; i < pairs; i++)
   {
      trade.PositionCloseBy(allBuys[i].ticket, allSells[i].ticket);
      Sleep(200);
   }

   // 3. Close any remaining positions normally
   CloseAllRemainingPositions();

   // 4. Reset EA state
   g_gridInitialized = false;
   g_anchorPrice     = 0.0;
   g_sessionLotSize  = 0.0;

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

   Print("GridHedgeEA: Symbol=", _Symbol,
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

   Print("GridHedgeEA: FillingMode=", fillingMode,
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

   // 5. Create the Close All button on the chart
   CreateCloseAllButton();

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| MAIN TICK HANDLER                                                  |
//+------------------------------------------------------------------+
void OnTick()
{
   if(!g_gridInitialized) return;

   // Skip all trading logic when AutoTrading is disabled or no connection
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED)) return;
   if(!TerminalInfoInteger(TERMINAL_CONNECTED)) return;

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
   // STEP 8.5: Market Order Grid — check price-level crossings
   // ============================================================
   ProcessMarketGridLevels();

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
   DestroyCloseAllButton();
   Comment("");  // Clear chart display
   Print("GridHedgeEA removed. Reason: ", reason,
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
