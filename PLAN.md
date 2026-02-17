# Complete EA Design Document: Bidirectional Grid Hedge Expert Advisor (MQL5)
# VERSION 2.0 — FINAL

## ROLE & CONTEXT
You are an expert MQL5 developer. Build a complete, production-ready Expert Advisor (single .mq5 file) based on the following detailed specification. The code must compile without errors or warnings in MetaEditor 5. Every function must be fully implemented — no placeholders, no pseudocode, no TODO comments. Read the ENTIRE document before writing any code.

---

## 1. STRATEGY OVERVIEW

This EA implements a **Bidirectional Grid + Hedge** strategy with triple-close basket mechanism, order replenishment, and order migration.

**How it works:**
1. Calculate a **Mid Price** (average of Ask and Bid) as the anchor point
2. Place a grid of **Buy Stop** orders above the anchor and **Sell Stop** orders below it
3. When pending orders activate (become market orders), immediately **replenish** by placing a new pending order of the same type at the far end
4. When both BUY and SELL positions exist simultaneously, use a **triple-close mechanism**: group 1 loser with 2 winners, close using CloseBy + normal close, then **migrate** 3 pending orders of the loser's type to the exact prices where the 3 closed positions were
5. When only one direction exists, close individual positions at the grid spacing profit target
6. When total floating profit reaches a **target percentage** of account balance, hedge all positions to neutral, then close everything via CloseBy, and restart

---

## 2. INPUT PARAMETERS

```mql5
//=== Grid Settings ===
input int      GridOrders         = 100;       // Number of pending orders PER SIDE (100 Buy Stops + 100 Sell Stops)
input double   GridSpacingPoints  = 50;        // Distance between each order in POINTS
input int      MagicNumber        = 777777;    // Unique EA identifier

//=== Lot Size Settings ===
input double   MinLot             = 0.01;      // Minimum lot size (used if balance is too low)

//=== Profit Settings ===
input double   TotalProfitPercent = 1.0;       // % of account balance to trigger full close & restart
// NOTE: Basket close profit threshold = GridSpacingPoints (same as distance between orders)
// NOTE: Individual position close profit = GridSpacingPoints

//=== Migration Settings ===
input bool     EnableMigration    = true;      // Enable/disable gap-filling migration feature
```

---

## 3. KEY DEFINITIONS

```
ANCHOR PRICE:       (Ask + Bid) / 2, calculated once at grid initialization, fixed until restart
GRID SPACING:       GridSpacingPoints in points — distance between consecutive orders
LOT SIZE:           Calculated so that account balance can support at least 4000 orders as margin
                    Fixed for the entire session/cycle. Recalculated only on restart.
BASKET PROFIT:      GridSpacingPoints converted to account currency — the minimum net profit 
                    required for a triple-close basket
SESSION/CYCLE:      From grid initialization until total profit target is reached and everything closes
REPLENISHMENT:      Adding a new pending order at the far end when one activates
MIGRATION:          Moving (modifying) existing pending orders to fill specific price levels
```

---

## 4. GLOBAL VARIABLES & DATA STRUCTURES

```mql5
#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\OrderInfo.mqh>

CTrade         trade;
CPositionInfo  posInfo;
COrderInfo     ordInfo;

// Anchor point — set on grid init, fixed until restart
double g_anchorPrice = 0.0;

// Session lot size — fixed for entire cycle
double g_sessionLotSize = 0.0;

// Flag to track if grid is active
bool g_gridInitialized = false;

// Symbol properties (cached on init)
double g_point;
int    g_digits;
double g_tickSize;
double g_tickValue;
double g_minLot;
double g_maxLot;
double g_lotStep;
int    g_stopLevel;
int    g_freezeLevel;

// Structure for position/order info
struct SOrderInfo
{
   ulong  ticket;
   double price;
   double profit;
   double lots;
   int    type;
};
```

---

## 5. LOT SIZE CALCULATION

```
FUNCTION CalculateSessionLotSize() -> double:
   // The lot size must allow the account to support AT LEAST 4000 orders
   // as margin (this ensures the account can handle the grid + replenishments)
   
   balance = AccountInfoDouble(ACCOUNT_BALANCE)
   
   // Get margin required for 1 lot of the symbol
   marginPerLot = 0.0
   OrderCalcMargin(ORDER_TYPE_BUY, _Symbol, 1.0, SymbolInfoDouble(_Symbol, SYMBOL_ASK), marginPerLot)
   
   // If marginPerLot is 0 or error, use a safe default
   IF marginPerLot <= 0:
      RETURN MinLot
   
   // Calculate lot size where: balance >= lotSize * marginPerLot * 4000
   // lotSize = balance / (marginPerLot * 4000)
   lotSize = balance / (marginPerLot * 4000.0)
   
   // Normalize to broker lot step
   lotSize = MathFloor(lotSize / g_lotStep) * g_lotStep
   
   // Apply limits
   lotSize = MathMax(lotSize, g_minLot)   // At least broker minimum
   lotSize = MathMax(lotSize, MinLot)      // At least user minimum
   lotSize = MathMin(lotSize, g_maxLot)    // Not above broker maximum
   
   lotSize = NormalizeDouble(lotSize, 2)
   RETURN lotSize
```

---

## 6. INITIALIZATION (OnInit)

```
PROCEDURE OnInit():
   1. Cache all symbol properties:
      g_point       = SymbolInfoDouble(_Symbol, SYMBOL_POINT)
      g_digits      = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)
      g_tickSize    = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE)
      g_tickValue   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE)
      g_minLot      = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN)
      g_maxLot      = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX)
      g_lotStep     = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP)
      g_stopLevel   = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL)
      g_freezeLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL)

   2. Set up CTrade:
      trade.SetExpertMagicNumber(MagicNumber)
      trade.SetDeviationInPoints(10)
      trade.SetTypeFilling(ORDER_FILLING_IOC)  // or detect from broker

   3. CRITICAL CHECK — Hedging account required:
      IF AccountInfoInteger(ACCOUNT_MARGIN_MODE) != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING:
         Alert("This EA requires a HEDGING account! EA will not start.")
         RETURN INIT_FAILED

   4. Check for existing orders/positions with this MagicNumber:
      IF existing orders or positions found:
         g_gridInitialized = true
         // Recover g_anchorPrice and g_sessionLotSize from existing orders
         // (e.g., from the midpoint of the grid or store in global variables)
      ELSE:
         InitializeGrid()
   
   5. RETURN INIT_SUCCEEDED
```

---

## 7. GRID INITIALIZATION (InitializeGrid)

```
PROCEDURE InitializeGrid():
   1. Calculate anchor price:
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK)
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID)
      g_anchorPrice = NormalizeDouble((ask + bid) / 2.0, g_digits)

   2. Calculate session lot size (fixed for this entire cycle):
      g_sessionLotSize = CalculateSessionLotSize()

   3. Get current spread in points:
      int spreadPoints = (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD)
      double halfSpread = (spreadPoints * g_point) / 2.0

   4. Place Buy Stop orders ABOVE anchor:
      FOR i = 1 TO GridOrders:
         double price = g_anchorPrice + halfSpread + (i * GridSpacingPoints * g_point)
         price = NormalizeDouble(price, g_digits)
         
         // Ensure price respects minimum stop level above Ask
         double minBuyStop = ask + g_stopLevel * g_point
         IF price <= minBuyStop:
            price = NormalizeDouble(minBuyStop + g_point, g_digits)
         
         PlacePendingOrder(ORDER_TYPE_BUY_STOP, price, g_sessionLotSize)

   5. Place Sell Stop orders BELOW anchor:
      FOR i = 1 TO GridOrders:
         double price = g_anchorPrice - halfSpread - (i * GridSpacingPoints * g_point)
         price = NormalizeDouble(price, g_digits)
         
         // Ensure price respects minimum stop level below Bid
         double minSellStop = bid - g_stopLevel * g_point
         IF price >= minSellStop:
            price = NormalizeDouble(minSellStop - g_point, g_digits)
         
         PlacePendingOrder(ORDER_TYPE_SELL_STOP, price, g_sessionLotSize)

   6. Set g_gridInitialized = true
   7. Log: "Grid initialized. Anchor=" + g_anchorPrice + " Lot=" + g_sessionLotSize
```

---

## 8. MAIN LOOP (OnTick)

```
PROCEDURE OnTick():

   IF !g_gridInitialized: RETURN

   // ============================================
   // STEP 1: Refresh market data
   // ============================================
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK)
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID)

   // ============================================
   // STEP 2: Collect all positions and pending orders
   // ============================================
   SOrderInfo buyPositions[]      // All open BUY positions, sorted by price ASCENDING
   SOrderInfo sellPositions[]     // All open SELL positions, sorted by price ASCENDING
   SOrderInfo buyStopOrders[]     // All pending BUY STOP orders, sorted by price ASCENDING
   SOrderInfo sellStopOrders[]    // All pending SELL STOP orders, sorted by price ASCENDING
   
   CollectAndSortPositions(buyPositions, sellPositions)
   CollectAndSortPendingOrders(buyStopOrders, sellStopOrders)
   
   int buyCount     = ArraySize(buyPositions)
   int sellCount    = ArraySize(sellPositions)
   int buyStopCount = ArraySize(buyStopOrders)
   int sellStopCount = ArraySize(sellStopOrders)

   // ============================================
   // STEP 3: Check Total Profit Target
   // ============================================
   double totalProfit = CalculateTotalFloatingProfit()
   double targetProfit = AccountInfoDouble(ACCOUNT_BALANCE) * TotalProfitPercent / 100.0
   
   IF totalProfit >= targetProfit AND (buyCount > 0 OR sellCount > 0):
      ExecuteFullClose(buyPositions, sellPositions, buyCount, sellCount)
      Sleep(2000)
      InitializeGrid()
      RETURN

   // ============================================
   // STEP 4: Replenish pending orders
   // (When a pending order activates, add new one at far end)
   // ============================================
   ReplenishPendingOrders(buyStopOrders, sellStopOrders, buyStopCount, sellStopCount)

   // ============================================
   // STEP 5: Basket Close Logic (ONLY when BOTH BUY and SELL positions exist)
   // ============================================
   IF buyCount > 0 AND sellCount > 0:
      TryBasketClose(buyPositions, sellPositions, buyCount, sellCount,
                     buyStopOrders, sellStopOrders, buyStopCount, sellStopCount)
      RETURN   // After any basket operation, wait for next tick to reprocess

   // ============================================
   // STEP 6: Single-direction profit close (when NO opposing positions)
   // ============================================
   IF buyCount > 0 AND sellCount == 0:
      CloseIndividualProfitable(buyPositions, buyCount, bid, POSITION_TYPE_BUY)
   
   IF sellCount > 0 AND buyCount == 0:
      CloseIndividualProfitable(sellPositions, sellCount, ask, POSITION_TYPE_SELL)

   // ============================================
   // STEP 7: Gap-filling Migration (ONLY when single direction AND enabled)
   // ============================================
   IF EnableMigration AND buyCount > 0 AND sellCount == 0:
      MigrateToFillGaps(DIRECTION_UP, buyPositions, buyCount,
                        buyStopOrders, sellStopOrders, buyStopCount, sellStopCount)
   
   IF EnableMigration AND sellCount > 0 AND buyCount == 0:
      MigrateToFillGaps(DIRECTION_DOWN, sellPositions, sellCount,
                        buyStopOrders, sellStopOrders, buyStopCount, sellStopCount)

   // ============================================
   // STEP 8: Update chart display
   // ============================================
   UpdateChartInfo(buyCount, sellCount, buyStopCount, sellStopCount, totalProfit, targetProfit)
```

---

## 9. BASKET CLOSE LOGIC (Triple Close)

This is the heart of the strategy. VERY IMPORTANT — read carefully.

```
PROCEDURE TryBasketClose(buyPositions[], sellPositions[], buyCount, sellCount,
                         buyStopOrders[], sellStopOrders[], buyStopCount, sellStopCount):

   // Calculate required profit in account currency
   // Required = GridSpacingPoints worth of profit in money
   double requiredProfitMoney = PointsToMoney(GridSpacingPoints, g_sessionLotSize)

   // -----------------------------------------------------------------
   // SCENARIO A: Price is RISING
   // BUY positions are winning, SELL positions are losing
   // Close: Lowest Sell (least losing / most losing doesn't matter — it's the lowest price)
   //        + Lowest 2 Buys (least winning by price — they are closest to the Sell)
   // -----------------------------------------------------------------
   IF buyCount >= 2 AND sellCount >= 1:
      
      // Arrays are sorted ASCENDING by price
      // Lowest Sell = sellPositions[0] (lowest price = most losing when price is rising)
      // Lowest 2 Buys = buyPositions[0] and buyPositions[1] (lowest prices)
      
      SOrderInfo loserSell   = sellPositions[0]
      SOrderInfo winnerBuy1  = buyPositions[0]    // lower price = less profit
      SOrderInfo winnerBuy2  = buyPositions[1]    // slightly higher = slightly less profit
      
      double combinedProfit = loserSell.profit + winnerBuy1.profit + winnerBuy2.profit
      
      IF combinedProfit >= requiredProfitMoney:
         
         // === STEP A1: Record the 3 closing prices BEFORE closing ===
         double closedPrice1 = loserSell.price    // Sell position price
         double closedPrice2 = winnerBuy1.price    // Buy position 1 price
         double closedPrice3 = winnerBuy2.price    // Buy position 2 price
         
         // === STEP A2: Determine which Buy is MORE profitable to use for CloseBy ===
         // CloseBy: the MOST profitable Buy closes against the SELL (loser)
         // The other Buy closes normally
         ulong closeByBuyTicket, normalCloseBuyTicket
         IF winnerBuy1.profit >= winnerBuy2.profit:
            closeByBuyTicket    = winnerBuy1.ticket
            normalCloseBuyTicket = winnerBuy2.ticket
         ELSE:
            closeByBuyTicket    = winnerBuy2.ticket
            normalCloseBuyTicket = winnerBuy1.ticket
         
         // === STEP A3: Migrate 3 farthest SELL STOP orders to the 3 closed prices ===
         // IMPORTANT: Do migration BEFORE closing, to ensure we have the prices
         // Take the 3 FARTHEST (lowest price) Sell Stops and modify them
         // sellStopOrders[] is sorted ASCENDING, so index 0 = lowest = farthest when price is up
         IF sellStopCount >= 3:
            ModifyPendingOrder(sellStopOrders[0].ticket, closedPrice1)
            ModifyPendingOrder(sellStopOrders[1].ticket, closedPrice2)
            ModifyPendingOrder(sellStopOrders[2].ticket, closedPrice3)
            // NOTE: closedPrice2 and closedPrice3 are BUY prices (above anchor)
            // These Sell Stops at high prices will act as reversal catchers
         
         // === STEP A4: Execute the closes ===
         // 1. CloseBy: Most profitable Buy against the losing Sell
         trade.PositionCloseBy(closeByBuyTicket, loserSell.ticket)
         Sleep(200)
         
         // 2. Normal close: The other Buy
         trade.PositionClose(normalCloseBuyTicket)
         
         RETURN

   // -----------------------------------------------------------------
   // SCENARIO B: Price is FALLING
   // SELL positions are winning, BUY positions are losing
   // Close: Highest Buy (most losing when price falls)
   //        + Highest 2 Sells (most winning by price)
   // -----------------------------------------------------------------
   IF sellCount >= 2 AND buyCount >= 1:
      
      // Highest Buy = buyPositions[buyCount - 1] (highest price = most losing when price falls)
      // Highest 2 Sells = sellPositions[sellCount - 1] and sellPositions[sellCount - 2]
      
      SOrderInfo loserBuy    = buyPositions[buyCount - 1]
      SOrderInfo winnerSell1 = sellPositions[sellCount - 1]    // highest price sell
      SOrderInfo winnerSell2 = sellPositions[sellCount - 2]    // second highest
      
      double combinedProfit = loserBuy.profit + winnerSell1.profit + winnerSell2.profit
      
      IF combinedProfit >= requiredProfitMoney:
         
         // === STEP B1: Record the 3 closing prices BEFORE closing ===
         double closedPrice1 = loserBuy.price      // Buy position price
         double closedPrice2 = winnerSell1.price    // Sell position 1 price
         double closedPrice3 = winnerSell2.price    // Sell position 2 price
         
         // === STEP B2: Determine which Sell is MORE profitable for CloseBy ===
         ulong closeBySellTicket, normalCloseSellTicket
         IF winnerSell1.profit >= winnerSell2.profit:
            closeBySellTicket    = winnerSell1.ticket
            normalCloseSellTicket = winnerSell2.ticket
         ELSE:
            closeBySellTicket    = winnerSell2.ticket
            normalCloseSellTicket = winnerSell1.ticket
         
         // === STEP B3: Migrate 3 farthest BUY STOP orders to the 3 closed prices ===
         // Take the 3 FARTHEST (highest price) Buy Stops and modify them
         // buyStopOrders[] sorted ASCENDING, so last indices = highest = farthest when price is down
         IF buyStopCount >= 3:
            ModifyPendingOrder(buyStopOrders[buyStopCount - 1].ticket, closedPrice1)
            ModifyPendingOrder(buyStopOrders[buyStopCount - 2].ticket, closedPrice2)
            ModifyPendingOrder(buyStopOrders[buyStopCount - 3].ticket, closedPrice3)
         
         // === STEP B4: Execute the closes ===
         // 1. CloseBy: Most profitable Sell against the losing Buy
         trade.PositionCloseBy(closeBySellTicket, loserBuy.ticket)
         Sleep(200)
         
         // 2. Normal close: The other Sell
         trade.PositionClose(normalCloseSellTicket)
         
         RETURN
```

### CRITICAL NOTES ON BASKET CLOSE:
```
1. Migration of pending orders happens BEFORE closing positions
   - This ensures we capture the exact prices before positions are gone
   - The 3 farthest pending orders of the LOSER'S TYPE get moved to the 3 closed prices
   
2. Why migrate loser's type?
   - If we closed 1 Sell (loser) + 2 Buys (winners) → we migrate 3 Sell Stops
   - If we closed 1 Buy (loser) + 2 Sells (winners) → we migrate 3 Buy Stops
   - This replaces the closed positions with pending orders that will catch price reversals
   
3. The number of pending orders stays CONSTANT because:
   - 3 positions are closed (reducing market orders by 3)
   - 3 pending orders are MOVED (not added or removed — just modified to new prices)
   - Net change in pending orders: 0

4. CloseBy saves spread because:
   - Instead of closing Buy (paying spread) + closing Sell (paying spread) = 2 spreads
   - CloseBy nets them against each other = 0 spread for that pair
   - Only the 3rd position pays spread on normal close = 1 spread total instead of 3
```

---

## 10. FULL CLOSE & RESTART PROCEDURE

When total floating profit >= TotalProfitPercent of balance:

```
PROCEDURE ExecuteFullClose(buyPositions[], sellPositions[], buyCount, sellCount):
   
   // === STEP 1: Calculate total lots on each side ===
   double totalBuyLots = 0
   FOR i = 0 TO buyCount - 1:
      totalBuyLots += buyPositions[i].lots
   
   double totalSellLots = 0
   FOR i = 0 TO sellCount - 1:
      totalSellLots += sellPositions[i].lots
   
   // === STEP 2: Hedge to neutral by opening an equalizing position ===
   double diff = MathAbs(totalBuyLots - totalSellLots)
   diff = NormalizeDouble(diff, 2)
   // Round up to lot step to ensure full coverage
   diff = MathCeil(diff / g_lotStep) * g_lotStep
   
   IF diff > 0:
      IF totalBuyLots > totalSellLots:
         // Need more SELL to balance
         trade.Sell(diff, _Symbol, 0, 0, 0, "Hedge to neutral")
      ELSE IF totalSellLots > totalBuyLots:
         // Need more BUY to balance
         trade.Buy(diff, _Symbol, 0, 0, 0, "Hedge to neutral")
      
      Sleep(500)
   
   // === STEP 3: Delete ALL pending orders ===
   DeleteAllPendingOrders()
   Sleep(500)
   
   // === STEP 4: Close all positions via CloseBy ===
   // Match each Buy with a Sell and close them against each other
   // This saves spread on every pair
   
   // Re-collect positions after hedging
   SOrderInfo allBuys[], allSells[]
   CollectAndSortPositions(allBuys, allSells)
   
   int bCount = ArraySize(allBuys)
   int sCount = ArraySize(allSells)
   
   // Close pairs via CloseBy
   int pairs = MathMin(bCount, sCount)
   FOR i = 0 TO pairs - 1:
      trade.PositionCloseBy(allBuys[i].ticket, allSells[i].ticket)
      Sleep(200)
   
   // Close any remaining positions normally (should be minimal or zero)
   // Re-collect to check for remainders
   CloseAllRemainingPositions()
   
   // === STEP 5: Reset state ===
   g_gridInitialized = false
   g_anchorPrice = 0
   g_sessionLotSize = 0
   
   Print("=== CYCLE COMPLETE === Profit target reached. Restarting...")
```

---

## 11. ORDER REPLENISHMENT

When a pending order activates (becomes a market order), immediately place a new pending order of the same type at the far end to maintain the grid count.

```
PROCEDURE ReplenishPendingOrders(buyStopOrders[], sellStopOrders[], 
                                  buyStopCount, sellStopCount):
   
   // Expected number of pending orders per side = GridOrders
   // (This stays constant throughout the session)
   
   // --- Replenish Buy Stops ---
   int missingBuyStops = GridOrders - buyStopCount
   
   IF missingBuyStops > 0:
      // Find the highest existing Buy Stop price
      double highestBuyStopPrice = 0
      IF buyStopCount > 0:
         highestBuyStopPrice = buyStopOrders[buyStopCount - 1].price  // sorted ascending, last = highest
      ELSE:
         // No Buy Stops exist — use highest Buy position price as reference
         // (This shouldn't normally happen but handle it)
         highestBuyStopPrice = GetHighestPositionPrice(POSITION_TYPE_BUY)
      
      // Place new Buy Stops above the highest existing one
      FOR i = 1 TO missingBuyStops:
         double newPrice = highestBuyStopPrice + (i * GridSpacingPoints * g_point)
         newPrice = NormalizeDouble(newPrice, g_digits)
         
         // Validate: must be above Ask + stopLevel
         double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK)
         IF newPrice > ask + g_stopLevel * g_point:
            PlacePendingOrder(ORDER_TYPE_BUY_STOP, newPrice, g_sessionLotSize)
   
   // --- Replenish Sell Stops ---
   int missingSellStops = GridOrders - sellStopCount
   
   IF missingSellStops > 0:
      double lowestSellStopPrice = DBL_MAX
      IF sellStopCount > 0:
         lowestSellStopPrice = sellStopOrders[0].price  // sorted ascending, first = lowest
      ELSE:
         lowestSellStopPrice = GetLowestPositionPrice(POSITION_TYPE_SELL)
      
      FOR i = 1 TO missingSellStops:
         double newPrice = lowestSellStopPrice - (i * GridSpacingPoints * g_point)
         newPrice = NormalizeDouble(newPrice, g_digits)
         
         double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID)
         IF newPrice < bid - g_stopLevel * g_point:
            PlacePendingOrder(ORDER_TYPE_SELL_STOP, newPrice, g_sessionLotSize)
```

---

## 12. GAP-FILLING MIGRATION

This is separate from the basket-close migration. This handles gaps between Buy and Sell orders when only one direction of market orders exists.

```
PROCEDURE MigrateToFillGaps(direction, marketPositions[], posCount,
                             buyStopOrders[], sellStopOrders[], 
                             buyStopCount, sellStopCount):
   
   // PURPOSE: When only BUY or only SELL positions exist,
   // move the farthest opposite pending orders to fill gaps
   // between the market positions and the nearest pending orders
   
   IF direction == DIRECTION_UP:
      // Only BUY positions exist, price is going up
      // Sell Stops may be far below and useless
      // Move farthest Sell Stops up to fill gap between:
      //   lowest Buy position and lowest Buy Stop
      
      IF sellStopCount == 0 OR posCount == 0: RETURN
      IF buyStopCount == 0: RETURN
      
      // Find the gap zone
      double lowestBuyPos = marketPositions[0].price           // lowest buy position
      double lowestBuyStop = buyStopOrders[0].price            // lowest buy stop
      double highestSellStop = sellStopOrders[sellStopCount-1].price  // highest sell stop
      
      // Gap is between the highest Sell Stop and the lowest Buy position/Buy Stop
      double gapBottom = highestSellStop
      double gapTop = MathMin(lowestBuyPos, lowestBuyStop)
      
      // If no real gap exists, nothing to do
      IF gapTop - gapBottom <= GridSpacingPoints * g_point * 2: RETURN
      
      // Calculate target prices to fill the gap (from top of gap downward)
      // Starting from: gapTop - GridSpacingPoints * point
      int slotsAvailable = (int)MathFloor((gapTop - gapBottom) / (GridSpacingPoints * g_point)) - 1
      IF slotsAvailable <= 0: RETURN
      
      // Take the farthest (lowest) Sell Stops and move them up
      int ordersToMove = MathMin(slotsAvailable, sellStopCount)
      
      FOR i = 0 TO ordersToMove - 1:
         double targetPrice = gapTop - ((i + 1) * GridSpacingPoints * g_point)
         targetPrice = NormalizeDouble(targetPrice, g_digits)
         
         double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID)
         IF targetPrice < bid - g_stopLevel * g_point:
            IF MathAbs(sellStopOrders[i].price - targetPrice) > g_point:
               ModifyPendingOrder(sellStopOrders[i].ticket, targetPrice)
   
   ELSE IF direction == DIRECTION_DOWN:
      // Only SELL positions exist, price is going down
      // Buy Stops may be far above and useless
      // Move farthest Buy Stops down to fill gap
      
      IF buyStopCount == 0 OR posCount == 0: RETURN
      IF sellStopCount == 0: RETURN
      
      double highestSellPos = marketPositions[posCount-1].price
      double highestSellStop = sellStopOrders[sellStopCount-1].price
      double lowestBuyStop = buyStopOrders[0].price
      
      double gapBottom = MathMax(highestSellPos, highestSellStop)
      double gapTop = lowestBuyStop
      
      IF gapTop - gapBottom <= GridSpacingPoints * g_point * 2: RETURN
      
      int slotsAvailable = (int)MathFloor((gapTop - gapBottom) / (GridSpacingPoints * g_point)) - 1
      IF slotsAvailable <= 0: RETURN
      
      int ordersToMove = MathMin(slotsAvailable, buyStopCount)
      
      // Take farthest (highest) Buy Stops and move them down
      FOR i = 0 TO ordersToMove - 1:
         int idx = buyStopCount - 1 - i   // start from highest
         double targetPrice = gapBottom + ((i + 1) * GridSpacingPoints * g_point)
         targetPrice = NormalizeDouble(targetPrice, g_digits)
         
         double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK)
         IF targetPrice > ask + g_stopLevel * g_point:
            IF MathAbs(buyStopOrders[idx].price - targetPrice) > g_point:
               ModifyPendingOrder(buyStopOrders[idx].ticket, targetPrice)
```

---

## 13. INDIVIDUAL PROFIT CLOSE (Single Direction Only)

```
PROCEDURE CloseIndividualProfitable(positions[], count, currentPrice, posType):
   // When only one direction exists (no hedge conflict),
   // close any position that has reached GridSpacingPoints profit
   
   FOR i = count - 1 DOWNTO 0:    // reverse loop since closing changes indices
      double profitPoints = 0
      
      IF posType == POSITION_TYPE_BUY:
         profitPoints = (currentPrice - positions[i].price) / g_point   // currentPrice = Bid
      ELSE:
         profitPoints = (positions[i].price - currentPrice) / g_point   // currentPrice = Ask
      
      IF profitPoints >= GridSpacingPoints:
         trade.PositionClose(positions[i].ticket)
         Sleep(100)
```

---

## 14. UTILITY FUNCTIONS

### 14.1 Points to Money Conversion
```
FUNCTION PointsToMoney(points, lots) -> double:
   // Convert a number of points to account currency for given lot size
   RETURN points * g_tickValue / g_tickSize * lots * g_point
   // Alternative simpler approach:
   // RETURN points * SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE) * lots
   // (if 1 point = 1 tick)
```

### 14.2 Place Pending Order with Error Handling
```
FUNCTION PlacePendingOrder(orderType, price, lots) -> bool:
   price = NormalizeDouble(price, g_digits)
   bool result = false
   
   FOR retry = 0 TO 2:    // max 3 attempts
      IF orderType == ORDER_TYPE_BUY_STOP:
         result = trade.BuyStop(lots, price, _Symbol, 0, 0, ORDER_TIME_GTC, 0, "GridEA BuyStop")
      ELSE IF orderType == ORDER_TYPE_SELL_STOP:
         result = trade.SellStop(lots, price, _Symbol, 0, 0, ORDER_TIME_GTC, 0, "GridEA SellStop")
      
      IF result: RETURN true
      
      uint error = trade.ResultRetcode()
      Print("PlacePendingOrder failed: ", trade.ResultRetcodeDescription(), " Price=", price)
      
      IF error == TRADE_RETCODE_INVALID_STOPS OR error == TRADE_RETCODE_INVALID_PRICE:
         // Price too close to market, adjust and retry
         IF orderType == ORDER_TYPE_BUY_STOP:
            price = SymbolInfoDouble(_Symbol, SYMBOL_ASK) + (g_stopLevel + 5) * g_point
         ELSE:
            price = SymbolInfoDouble(_Symbol, SYMBOL_BID) - (g_stopLevel + 5) * g_point
         price = NormalizeDouble(price, g_digits)
      
      Sleep(300)
   
   RETURN false
```

### 14.3 Modify Pending Order
```
FUNCTION ModifyPendingOrder(ticket, newPrice) -> bool:
   newPrice = NormalizeDouble(newPrice, g_digits)
   
   FOR retry = 0 TO 2:
      // Need to select the order first to get its details
      IF !OrderSelect(ticket): RETURN false
      
      // Check freeze level — can't modify if price is too close to current price
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK)
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID)
      int ordType = (int)OrderGetInteger(ORDER_TYPE)
      
      IF ordType == ORDER_TYPE_BUY_STOP:
         IF newPrice <= ask + g_stopLevel * g_point:
            Print("ModifyPendingOrder: price too close to Ask. Skipping.")
            RETURN false
      ELSE IF ordType == ORDER_TYPE_SELL_STOP:
         IF newPrice >= bid - g_stopLevel * g_point:
            Print("ModifyPendingOrder: price too close to Bid. Skipping.")
            RETURN false
      
      bool result = trade.OrderModify(ticket, newPrice, 0, 0, ORDER_TIME_GTC, 0)
      IF result: RETURN true
      
      Print("ModifyPendingOrder failed: ", trade.ResultRetcodeDescription())
      Sleep(300)
   
   RETURN false
```

### 14.4 Collect and Sort Positions
```
FUNCTION CollectAndSortPositions(&buyPositions[], &sellPositions[]):
   ArrayResize(buyPositions, 0)
   ArrayResize(sellPositions, 0)
   
   FOR i = 0 TO PositionsTotal() - 1:
      ulong ticket = PositionGetTicket(i)
      IF ticket == 0: CONTINUE
      IF PositionGetString(POSITION_SYMBOL) != _Symbol: CONTINUE
      IF PositionGetInteger(POSITION_MAGIC) != MagicNumber: CONTINUE
      
      SOrderInfo info
      info.ticket = ticket
      info.price  = PositionGetDouble(POSITION_PRICE_OPEN)
      info.profit = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP)
      info.lots   = PositionGetDouble(POSITION_VOLUME)
      info.type   = (int)PositionGetInteger(POSITION_TYPE)
      
      IF info.type == POSITION_TYPE_BUY:
         int size = ArraySize(buyPositions)
         ArrayResize(buyPositions, size + 1)
         buyPositions[size] = info
      ELSE IF info.type == POSITION_TYPE_SELL:
         int size = ArraySize(sellPositions)
         ArrayResize(sellPositions, size + 1)
         sellPositions[size] = info
   
   // Sort both arrays by price ASCENDING
   SortByPriceAscending(buyPositions)
   SortByPriceAscending(sellPositions)
```

### 14.5 Collect and Sort Pending Orders
```
FUNCTION CollectAndSortPendingOrders(&buyStopOrders[], &sellStopOrders[]):
   ArrayResize(buyStopOrders, 0)
   ArrayResize(sellStopOrders, 0)
   
   FOR i = 0 TO OrdersTotal() - 1:
      ulong ticket = OrderGetTicket(i)
      IF ticket == 0: CONTINUE
      IF OrderGetString(ORDER_SYMBOL) != _Symbol: CONTINUE
      IF OrderGetInteger(ORDER_MAGIC) != MagicNumber: CONTINUE
      
      SOrderInfo info
      info.ticket = ticket
      info.price  = OrderGetDouble(ORDER_PRICE_OPEN)
      info.profit = 0
      info.lots   = OrderGetDouble(ORDER_VOLUME_CURRENT)
      info.type   = (int)OrderGetInteger(ORDER_TYPE)
      
      IF info.type == ORDER_TYPE_BUY_STOP:
         int size = ArraySize(buyStopOrders)
         ArrayResize(buyStopOrders, size + 1)
         buyStopOrders[size] = info
      ELSE IF info.type == ORDER_TYPE_SELL_STOP:
         int size = ArraySize(sellStopOrders)
         ArrayResize(sellStopOrders, size + 1)
         sellStopOrders[size] = info
   
   SortByPriceAscending(buyStopOrders)
   SortByPriceAscending(sellStopOrders)
```

### 14.6 Sort Array by Price
```
FUNCTION SortByPriceAscending(&arr[]):
   // Simple bubble sort (arrays are typically small enough)
   int n = ArraySize(arr)
   FOR i = 0 TO n - 2:
      FOR j = 0 TO n - 2 - i:
         IF arr[j].price > arr[j+1].price:
            SOrderInfo temp = arr[j]
            arr[j] = arr[j+1]
            arr[j+1] = temp
```

### 14.7 Calculate Total Floating Profit
```
FUNCTION CalculateTotalFloatingProfit() -> double:
   double total = 0.0
   FOR i = 0 TO PositionsTotal() - 1:
      ulong ticket = PositionGetTicket(i)
      IF ticket == 0: CONTINUE
      IF PositionGetString(POSITION_SYMBOL) != _Symbol: CONTINUE
      IF PositionGetInteger(POSITION_MAGIC) != MagicNumber: CONTINUE
      total += PositionGetDouble(POSITION_PROFIT)
      total += PositionGetDouble(POSITION_SWAP)
   RETURN total
```

### 14.8 Delete All Pending Orders
```
FUNCTION DeleteAllPendingOrders():
   FOR i = OrdersTotal() - 1 DOWNTO 0:
      ulong ticket = OrderGetTicket(i)
      IF ticket == 0: CONTINUE
      IF OrderGetString(ORDER_SYMBOL) != _Symbol: CONTINUE
      IF OrderGetInteger(ORDER_MAGIC) != MagicNumber: CONTINUE
      trade.OrderDelete(ticket)
      Sleep(100)
```

### 14.9 Close All Remaining Positions
```
FUNCTION CloseAllRemainingPositions():
   FOR i = PositionsTotal() - 1 DOWNTO 0:
      ulong ticket = PositionGetTicket(i)
      IF ticket == 0: CONTINUE
      IF PositionGetString(POSITION_SYMBOL) != _Symbol: CONTINUE
      IF PositionGetInteger(POSITION_MAGIC) != MagicNumber: CONTINUE
      trade.PositionClose(ticket)
      Sleep(100)
```

### 14.10 Get Highest/Lowest Position Price
```
FUNCTION GetHighestPositionPrice(posType) -> double:
   double highest = 0
   FOR i = 0 TO PositionsTotal() - 1:
      ulong ticket = PositionGetTicket(i)
      IF PositionGetString(POSITION_SYMBOL) != _Symbol: CONTINUE
      IF PositionGetInteger(POSITION_MAGIC) != MagicNumber: CONTINUE
      IF PositionGetInteger(POSITION_TYPE) != posType: CONTINUE
      double price = PositionGetDouble(POSITION_PRICE_OPEN)
      IF price > highest: highest = price
   RETURN highest

FUNCTION GetLowestPositionPrice(posType) -> double:
   double lowest = DBL_MAX
   // Same logic but track lowest
   RETURN lowest
```

---

## 15. CHART DISPLAY

```
PROCEDURE UpdateChartInfo(buyCount, sellCount, buyStopCount, sellStopCount, 
                           totalProfit, targetProfit):
   
   double balance = AccountInfoDouble(ACCOUNT_BALANCE)
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY)
   double progress = (targetProfit > 0) ? (totalProfit / targetProfit * 100.0) : 0
   
   string info = ""
   info += "╔══════════════════════════════════╗\n"
   info += "║     GRID HEDGE EA v2.0           ║\n"
   info += "╠══════════════════════════════════╣\n"
   info += "║ Anchor Price:  " + DoubleToString(g_anchorPrice, g_digits) + "\n"
   info += "║ Session Lot:   " + DoubleToString(g_sessionLotSize, 2) + "\n"
   info += "║ Grid Spacing:  " + IntegerToString((int)GridSpacingPoints) + " points\n"
   info += "╠══════════════════════════════════╣\n"
   info += "║ BUY Positions:   " + IntegerToString(buyCount) + "\n"
   info += "║ SELL Positions:  " + IntegerToString(sellCount) + "\n"
   info += "║ Buy Stops:       " + IntegerToString(buyStopCount) + "\n"
   info += "║ Sell Stops:      " + IntegerToString(sellStopCount) + "\n"
   info += "╠══════════════════════════════════╣\n"
   info += "║ Floating P/L:  $" + DoubleToString(totalProfit, 2) + "\n"
   info += "║ Target (" + DoubleToString(TotalProfitPercent,1) + "%): $" + DoubleToString(targetProfit, 2) + "\n"
   info += "║ Progress:      " + DoubleToString(progress, 1) + "%\n"
   info += "╠══════════════════════════════════╣\n"
   info += "║ Balance: $" + DoubleToString(balance, 2) + "\n"
   info += "║ Equity:  $" + DoubleToString(equity, 2) + "\n"
   info += "║ Migration: " + (EnableMigration ? "ON" : "OFF") + "\n"
   info += "╚══════════════════════════════════╝\n"
   
   Comment(info)
```

---

## 16. OnDeinit

```
PROCEDURE OnDeinit(const int reason):
   Comment("")   // Clear chart display
   Print("Grid Hedge EA removed. Reason: ", reason)
   // NOTE: Do NOT close positions or delete orders on deinit
   // The user may want to restart the EA and resume
```

---

## 17. ERROR HANDLING RULES

```
ALL trade operations MUST follow these rules:

1. Every trade.XXX() call must check the return value
2. On failure, log: function name, error code, error description, relevant prices/tickets
3. Retry up to 3 times with Sleep(200-500ms) between retries
4. Handle specific errors:
   - TRADE_RETCODE_REQUOTE     → Refresh rates, retry
   - TRADE_RETCODE_REJECT      → Wait 500ms, retry
   - TRADE_RETCODE_ERROR       → Log and skip
   - TRADE_RETCODE_TIMEOUT     → Wait 1000ms, retry
   - TRADE_RETCODE_INVALID     → Log and skip (don't retry)
   - TRADE_RETCODE_INVALID_STOPS → Adjust price to respect stop level, retry
   - TRADE_RETCODE_TOO_MANY_REQUESTS → Wait 2000ms, retry
   - TRADE_RETCODE_NO_MONEY    → Log critical warning, skip

5. After CloseBy: always Sleep(200) before next operation
   (MetaTrader needs time to process the netting)
```

---

## 18. COMPLETE EXECUTION FLOW

```
[EA START]
    │
    ▼
[OnInit]
    │ Cache symbol info
    │ Check hedging account
    │ Check existing grid
    │
    ├─ (No existing grid) ──► [InitializeGrid]
    │                            │ Anchor = (Ask+Bid)/2
    │                            │ Lot = Balance / (MarginPerLot * 4000)
    │                            │ Place N Buy Stops above
    │                            │ Place N Sell Stops below
    │                            ▼
    ├─ (Grid exists) ──────────►│
    │                            │
    ▼                            ▼
[OnTick] ◄──────────────────────────
    │
    ▼
[Check Total Profit >= X% of Balance?]
    │
    ├─ YES ──► [Hedge to neutral] → [Delete pendings] → [CloseBy all pairs] → [Restart]
    │
    ▼ NO
[Collect & Sort all positions and pending orders]
    │
    ▼
[Replenish: Any pending activated? Add new at far end]
    │
    ▼
[Both BUY and SELL positions exist?]
    │
    ├─ YES ──► [Try Basket Close]
    │            │ Price UP: lowestSell + lowest2Buys
    │            │ Price DOWN: highestBuy + highest2Sells
    │            │ If profit >= GridSpacing:
    │            │   1. Record 3 prices
    │            │   2. Migrate 3 farthest opposite pendings to those prices
    │            │   3. CloseBy (most profitable winner vs loser)
    │            │   4. Normal close (other winner)
    │            ▼
    │          [RETURN — wait for next tick]
    │
    ▼ NO (single direction)
[Close individual positions at GridSpacing profit]
    │
    ▼
[Gap-filling Migration] (if enabled)
    │ Move farthest opposite pendings to fill gaps near price
    │ Maintain GridSpacing between orders
    │
    ▼
[Update Chart Display]
    │
    ▼
[Wait for next tick] ──────────► [OnTick]
```

---

## 19. OUTPUT REQUIREMENTS

1. **Single .mq5 file** — complete, compilable, production-ready
2. **All functions fully implemented** — no stubs, no pseudocode, no TODOs
3. **Well-commented code** — header comment for each function explaining its purpose
4. **Use CTrade, CPositionInfo, COrderInfo** from standard library
5. **Input parameters** exactly as specified in Section 2
6. **Chart display panel** as specified in Section 15
7. **Error handling** on every trade operation as specified in Section 17
8. **Hedging account verification** in OnInit
9. **Lot size calculation** supporting 4000 orders as margin
10. **OrderCloseBy** used wherever specified (basket close + full close)

---

## 20. TESTING CHECKLIST

After building, mentally verify:
- [ ] Grid places correct number of orders on both sides of anchor
- [ ] Anchor is (Ask+Bid)/2 and is fixed until restart
- [ ] Lot size is calculated correctly and stays fixed during session
- [ ] Pending orders are replenished when activated (same type, far end)
- [ ] Basket close identifies correct 3 positions (1 loser + 2 winners)
- [ ] CloseBy pairs the MOST profitable winner with the loser
- [ ] After basket close, 3 farthest pending orders of LOSER'S type migrate to closed prices
- [ ] Migration happens BEFORE position closing (to capture prices)
- [ ] Gap-filling migration works in single-direction mode
- [ ] Total profit check triggers hedge→delete→CloseBy→restart sequence
- [ ] Number of pending orders stays constant throughout session
- [ ] EA resumes correctly after terminal restart
- [ ] All trade operations have retry logic and error handling
- [ ] Works on any symbol (forex, crypto, gold, indices)
