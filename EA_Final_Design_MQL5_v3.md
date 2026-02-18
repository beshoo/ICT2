# Complete EA Design Document: Bidirectional Grid Hedge Expert Advisor (MQL5)
# VERSION 3.0 — FINAL

## ROLE & CONTEXT
You are an expert MQL5 developer. Build a complete, production-ready Expert Advisor (single .mq5 file) based on the following detailed specification. The code must compile without errors or warnings in MetaEditor 5. Every function must be fully implemented — no placeholders, no pseudocode, no TODO comments. Read the ENTIRE document before writing any code.

---

## 1. STRATEGY OVERVIEW

This EA implements a **Bidirectional Grid + Hedge** strategy with triple-close basket mechanism, order replenishment, order migration, gradual profit-taking, and market-close protection.

**How it works:**
1. Calculate a **Mid Price** (average of Ask and Bid) as the anchor point
2. Place a grid of **Buy Stop** orders above the anchor and **Sell Stop** orders below it
3. When pending orders activate (become market orders), immediately **replenish** by placing a new pending order of the same type at the far end
4. When both BUY and SELL positions exist simultaneously, use a **triple-close mechanism**: group 1 loser with 2 winners, close using CloseBy + normal close, then **migrate** 3 pending orders of the loser's type to the exact prices where the 3 closed positions were
5. When only one direction exists and count exceeds half of GridOrders, **gradually close** the most profitable one at a time, and migrate an opposite pending order to its price
6. Fill any **gaps** between Buy and Sell orders by migrating farthest opposite pending orders
7. When total floating profit reaches a **target percentage** of account balance, hedge to neutral, then close everything via CloseBy, and restart
8. **Before market close** (configurable hours), stop all new operations and close everything if floating P/L reaches zero or positive
9. **Next trading day**, automatically restart with a fresh grid

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

//=== Migration Settings ===
input bool     EnableMigration    = true;      // Enable/disable gap-filling migration feature

//=== Market Close Protection ===
input bool     UseMarketCloseProtection = true;   // Enable market close protection
input int      HoursBeforeClose         = 2;      // Hours before market close to activate protection
input int      TradingStartHour         = 1;      // Hour (server time) to start new trading day (auto-restart)
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
SESSION/CYCLE:      From grid initialization until total profit target is reached or market close protection triggers
REPLENISHMENT:      Adding a new pending order at the far end when one activates
MIGRATION:          Moving (modifying) existing pending orders to fill specific price levels
HALF GRID:          GridOrders / 2 — the maximum number of open positions allowed in one direction
                    before gradual closing begins
MARKET CLOSE MODE:  A protective state activated HoursBeforeClose before market close:
                    no new orders, no migrations, only monitoring for break-even to close all
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

// Grid state flags
bool g_gridInitialized = false;
bool g_marketCloseMode = false;      // True when in market close protection mode
bool g_waitingForNewDay = false;     // True when everything is closed, waiting for next day

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
   // The lot size must allow the account to support AT LEAST 4000 orders as margin
   
   balance = AccountInfoDouble(ACCOUNT_BALANCE)
   
   // Get margin required for 1 lot of the symbol
   marginPerLot = 0.0
   OrderCalcMargin(ORDER_TYPE_BUY, _Symbol, 1.0, SymbolInfoDouble(_Symbol, SYMBOL_ASK), marginPerLot)
   
   IF marginPerLot <= 0:
      RETURN MinLot
   
   // lotSize = balance / (marginPerLot * 4000)
   lotSize = balance / (marginPerLot * 4000.0)
   
   // Normalize to broker lot step
   lotSize = MathFloor(lotSize / g_lotStep) * g_lotStep
   
   // Apply limits
   lotSize = MathMax(lotSize, g_minLot)
   lotSize = MathMax(lotSize, MinLot)
   lotSize = MathMin(lotSize, g_maxLot)
   
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
      trade.SetTypeFilling(ORDER_FILLING_IOC)

   3. CRITICAL CHECK — Hedging account required:
      IF AccountInfoInteger(ACCOUNT_MARGIN_MODE) != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING:
         Alert("This EA requires a HEDGING account! EA will not start.")
         RETURN INIT_FAILED

   4. Check for existing orders/positions with this MagicNumber:
      IF existing orders or positions found:
         g_gridInitialized = true
         // Recover g_anchorPrice and g_sessionLotSize from existing grid
      ELSE:
         // Check if we should wait for new day or start immediately
         IF IsMarketCloseProtectionTime():
            g_waitingForNewDay = true
         ELSE:
            InitializeGrid()
   
   5. RETURN INIT_SUCCEEDED
```

---

## 7. GRID INITIALIZATION (InitializeGrid) — Far-to-Near Placement

### PLACEMENT ALGORITHM OVERVIEW:
```
The grid is placed starting from the point FARTHEST from current price, working inward:

  1. Calculate anchor (midpoint) and all grid levels above/below it
  2. Buy Stops: place from HIGHEST level (farthest) DOWNWARD toward price
  3. Sell Stops: place from LOWEST level (farthest) UPWARD toward price
  4. If a placement fails (price caught up, or freeze zone reached):
     — STOP placing in that direction
     — Count how many were successfully placed
     — Relocate remaining orders to the FAR END:
         • Unplaced Buy Stops → stack ABOVE the highest existing buy stop
         • Unplaced Sell Stops → stack BELOW the lowest existing sell stop
  5. This guarantees the total order count (GridOrders per side) is always met
  6. After placement completes, run Shifting/Rebalancing to fill any gaps

WHY far-to-near?
  - Orders far from price never fail (they're safely above Ask / below Bid)
  - Orders near price are placed LAST, so if they fail, we relocate them to the safe far end
  - During the 1-2 minutes of initialization, price may move significantly
  - This eliminates the "invalid price" / "rejected" errors seen with near-to-far placement
```

```
PROCEDURE InitializeGrid():
   // ============================================================
   // STEP 1: Calculate anchor and session lot size
   // ============================================================
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK)
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID)
   g_anchorPrice = NormalizeDouble((ask + bid) / 2.0, g_digits)
   g_sessionLotSize = CalculateSessionLotSize()

   int spreadPoints = (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD)
   double halfSpread = (spreadPoints * g_point) / 2.0
   double spacing = GridSpacingPoints * g_point

   // ============================================================
   // STEP 2: Pre-calculate ALL grid levels
   // ============================================================
   double buyLevels[]     // GridOrders levels above anchor
   double sellLevels[]    // GridOrders levels below anchor
   ArrayResize(buyLevels, GridOrders)
   ArrayResize(sellLevels, GridOrders)

   FOR i = 0 TO GridOrders - 1:
      // Buy levels: anchor + halfSpread + (1..N) * spacing
      buyLevels[i] = NormalizeDouble(g_anchorPrice + halfSpread + ((i + 1) * spacing), g_digits)
      // Sell levels: anchor - halfSpread - (1..N) * spacing
      sellLevels[i] = NormalizeDouble(g_anchorPrice - halfSpread - ((i + 1) * spacing), g_digits)

   // buyLevels[0] = closest to price, buyLevels[GridOrders-1] = farthest
   // sellLevels[0] = closest to price, sellLevels[GridOrders-1] = farthest

   // ============================================================
   // STEP 3: Place BUY STOPS — from FARTHEST (highest) to nearest (lowest)
   // ============================================================
   int buyPlaced = 0
   double highestBuyPlaced = 0

   FOR i = GridOrders - 1 DOWNTO 0:     // Start from farthest (highest price)
      double price = buyLevels[i]

      // Refresh Ask for each order (price may have moved)
      ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK)

      // Buy Stop must be ABOVE current Ask + stopLevel
      double minBuyStop = ask + MathMax(g_stopLevel, (int)GridSpacingPoints) * g_point
      IF price <= ask:
         // Price has caught up to or passed this level — STOP placing downward
         Print("InitializeGrid: Buy stop level ", price, " <= Ask ", ask, ". Stopping downward placement.")
         BREAK

      // Check freeze zone — if price is within freeze distance, stop
      IF g_freezeLevel > 0 AND (price - ask) <= g_freezeLevel * g_point:
         Print("InitializeGrid: Buy stop level ", price, " within freeze zone of Ask ", ask, ". Stopping.")
         BREAK

      bool ok = PlacePendingOrder(ORDER_TYPE_BUY_STOP, price, g_sessionLotSize)
      IF ok:
         buyPlaced++
         IF price > highestBuyPlaced OR highestBuyPlaced == 0:
            highestBuyPlaced = price

   // --- Relocate remaining Buy Stops to the FAR END (above highest placed) ---
   int buyRemaining = GridOrders - buyPlaced
   IF buyRemaining > 0 AND highestBuyPlaced > 0:
      Print("InitializeGrid: ", buyRemaining, " buy stops couldn't be placed near price. Relocating to far end.")
      FOR i = 1 TO buyRemaining:
         double price = NormalizeDouble(highestBuyPlaced + (i * spacing), g_digits)
         PlacePendingOrder(ORDER_TYPE_BUY_STOP, price, g_sessionLotSize)
         buyPlaced++

   // ============================================================
   // STEP 4: Place SELL STOPS — from FARTHEST (lowest) to nearest (highest)
   // ============================================================
   int sellPlaced = 0
   double lowestSellPlaced = DBL_MAX

   FOR i = GridOrders - 1 DOWNTO 0:     // Start from farthest (lowest price)
      double price = sellLevels[i]

      // Refresh Bid for each order
      bid = SymbolInfoDouble(_Symbol, SYMBOL_BID)

      // Sell Stop must be BELOW current Bid - stopLevel
      IF price >= bid:
         // Price has dropped to or below this level — STOP placing upward
         Print("InitializeGrid: Sell stop level ", price, " >= Bid ", bid, ". Stopping upward placement.")
         BREAK

      // Check freeze zone
      IF g_freezeLevel > 0 AND (bid - price) <= g_freezeLevel * g_point:
         Print("InitializeGrid: Sell stop level ", price, " within freeze zone of Bid ", bid, ". Stopping.")
         BREAK

      bool ok = PlacePendingOrder(ORDER_TYPE_SELL_STOP, price, g_sessionLotSize)
      IF ok:
         sellPlaced++
         IF price < lowestSellPlaced:
            lowestSellPlaced = price

   // --- Relocate remaining Sell Stops to the FAR END (below lowest placed) ---
   int sellRemaining = GridOrders - sellPlaced
   IF sellRemaining > 0 AND lowestSellPlaced < DBL_MAX:
      Print("InitializeGrid: ", sellRemaining, " sell stops couldn't be placed near price. Relocating to far end.")
      FOR i = 1 TO sellRemaining:
         double price = NormalizeDouble(lowestSellPlaced - (i * spacing), g_digits)
         PlacePendingOrder(ORDER_TYPE_SELL_STOP, price, g_sessionLotSize)
         sellPlaced++

   // ============================================================
   // STEP 5: Set flags and log actual results
   // ============================================================
   g_gridInitialized = true
   g_marketCloseMode = false
   g_waitingForNewDay = false

   // Count actual orders placed (verify against broker)
   SOrderInfo buyStops[], sellStops[]
   CollectAndSortPendingOrders(buyStops, sellStops)
   int actualBuyStops = ArraySize(buyStops)
   int actualSellStops = ArraySize(sellStops)

   Print("=== GRID INITIALIZED === Anchor=", g_anchorPrice,
         " Lot=", g_sessionLotSize,
         " BuyStops=", actualBuyStops, "/", GridOrders,
         " SellStops=", actualSellStops, "/", GridOrders)

   // ============================================================
   // STEP 6: Schedule immediate Shifting/Rebalancing on next tick
   // (handled by ReplenishPendingOrders + MigrateToFillGaps in OnTick)
   // Any gaps from the init process will be filled automatically
   // ============================================================
```

### CRITICAL NOTES ON FAR-TO-NEAR PLACEMENT:
```
1. Grid levels are pre-calculated based on anchor price at init time
2. Placement starts at the SAFEST point (farthest from price) and works inward
3. When price catches up to a level during placement:
   - We STOP going closer (all remaining levels would also fail)
   - We RELOCATE those orders to the far end instead
4. This means the grid may temporarily have a GAP near current price
   - The gap is filled on the NEXT tick by ReplenishPendingOrders + MigrateToFillGaps
5. Total order count (GridOrders per side) is ALWAYS guaranteed
6. No "invalid price" or "rejected" errors during init because:
   - Far orders always succeed (safely away from price)
   - Near orders that would fail are never sent — they go to the far end instead
```

---

## 8. MARKET CLOSE PROTECTION

```
FUNCTION IsMarketCloseProtectionTime() -> bool:
   IF !UseMarketCloseProtection: RETURN false
   
   // Get the trading session close time for the current symbol
   // MQL5: Use SymbolInfoSessionTrade() to get session end time
   // Or use a simpler approach based on known market hours
   
   datetime serverTime = TimeCurrent()
   MqlDateTime dt
   TimeToStruct(serverTime, dt)
   
   // Get session close time
   // For most forex/gold: session ends around 23:55-00:00 server time (varies by broker)
   // Use SymbolInfoSessionTrade to get actual close time
   
   datetime sessionStart, sessionEnd
   bool hasSession = SymbolInfoSessionTrade(_Symbol, (ENUM_DAY_OF_WEEK)dt.day_of_week, 
                                             0, sessionStart, sessionEnd)
   
   IF !hasSession: RETURN false
   
   // Convert session times to comparable format
   MqlDateTime dtEnd
   TimeToStruct(sessionEnd, dtEnd)
   
   // Calculate minutes until close
   int currentMinutes = dt.hour * 60 + dt.min
   int closeMinutes = dtEnd.hour * 60 + dtEnd.min
   int minutesUntilClose = closeMinutes - currentMinutes
   
   // Handle day wrap-around
   IF minutesUntilClose < 0:
      minutesUntilClose += 24 * 60
   
   // If within HoursBeforeClose hours of market close
   IF minutesUntilClose <= HoursBeforeClose * 60 AND minutesUntilClose >= 0:
      RETURN true
   
   RETURN false

FUNCTION IsNewTradingDay() -> bool:
   // Check if current hour matches TradingStartHour and we were waiting
   MqlDateTime dt
   TimeToStruct(TimeCurrent(), dt)
   
   // Check if it's the start hour and market is open
   IF dt.hour == TradingStartHour:
      // Verify market is actually open (not weekend)
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK)
      IF ask > 0: RETURN true
   
   RETURN false
```

---

## 9. MAIN LOOP (OnTick)

```
PROCEDURE OnTick():

   // ============================================
   // STEP 0: Waiting for new day (after market close protection closed everything)
   // ============================================
   IF g_waitingForNewDay:
      IF IsNewTradingDay():
         g_waitingForNewDay = false
         InitializeGrid()
      RETURN

   IF !g_gridInitialized: RETURN

   // ============================================
   // STEP 1: Refresh market data
   // ============================================
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK)
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID)

   // ============================================
   // STEP 2: Collect all positions and pending orders
   // ============================================
   SOrderInfo buyPositions[]
   SOrderInfo sellPositions[]
   SOrderInfo buyStopOrders[]
   SOrderInfo sellStopOrders[]
   
   CollectAndSortPositions(buyPositions, sellPositions)
   CollectAndSortPendingOrders(buyStopOrders, sellStopOrders)
   
   int buyCount      = ArraySize(buyPositions)
   int sellCount     = ArraySize(sellPositions)
   int buyStopCount  = ArraySize(buyStopOrders)
   int sellStopCount = ArraySize(sellStopOrders)
   int totalPositions = buyCount + sellCount

   // ============================================
   // STEP 3: Market Close Protection Check
   // ============================================
   IF UseMarketCloseProtection AND !g_marketCloseMode:
      IF IsMarketCloseProtectionTime():
         g_marketCloseMode = true
         Print("=== MARKET CLOSE PROTECTION ACTIVATED ===")

   IF g_marketCloseMode:
      // In market close mode:
      // - NO new orders
      // - NO replenishment
      // - NO migration
      // - ONLY monitor floating P/L
      
      IF totalPositions == 0:
         // No positions open — just wait for new day
         DeleteAllPendingOrders()
         g_gridInitialized = false
         g_waitingForNewDay = true
         Print("No positions. Waiting for new trading day.")
         RETURN
      
      double totalProfit = CalculateTotalFloatingProfit()
      IF totalProfit >= 0:
         // Break-even or profit reached — close everything
         Print("Market close protection: P/L >= 0 ($", totalProfit, "). Closing all.")
         ExecuteFullClose(buyPositions, sellPositions, buyCount, sellCount)
         DeleteAllPendingOrders()
         g_gridInitialized = false
         g_waitingForNewDay = true
         RETURN
      
      // Still in loss — keep monitoring, do nothing else
      UpdateChartInfo(buyCount, sellCount, buyStopCount, sellStopCount, 
                      totalProfit, 0, "MARKET CLOSE PROTECTION - Waiting for breakeven")
      RETURN

   // ============================================
   // STEP 4: Check Total Profit Target (1% of balance)
   // ============================================
   double totalProfit = CalculateTotalFloatingProfit()
   double balance = AccountInfoDouble(ACCOUNT_BALANCE)
   double targetProfit = balance * TotalProfitPercent / 100.0
   
   IF totalProfit >= targetProfit AND totalPositions > 0:
      ExecuteFullClose(buyPositions, sellPositions, buyCount, sellCount)
      Sleep(2000)
      InitializeGrid()
      RETURN

   // ============================================
   // STEP 5: Replenish pending orders
   // (When a pending order activates, add new one at far end)
   // ============================================
   ReplenishPendingOrders(buyStopOrders, sellStopOrders, buyStopCount, sellStopCount)

   // ============================================
   // STEP 6: Basket Close Logic (ONLY when BOTH BUY and SELL positions exist)
   // ============================================
   IF buyCount > 0 AND sellCount > 0:
      // Re-collect pending orders after replenishment (they may have changed)
      CollectAndSortPendingOrders(buyStopOrders, sellStopOrders)
      buyStopCount  = ArraySize(buyStopOrders)
      sellStopCount = ArraySize(sellStopOrders)
      
      TryBasketClose(buyPositions, sellPositions, buyCount, sellCount,
                     buyStopOrders, sellStopOrders, buyStopCount, sellStopCount)
      RETURN   // After any basket operation, wait for next tick

   // ============================================
   // STEP 7: Gradual Close (single direction, count > half grid)
   // ============================================
   IF buyCount > 0 AND sellCount == 0:
      int halfGrid = GridOrders / 2
      IF buyCount > halfGrid:
         GradualClose(buyPositions, buyCount, POSITION_TYPE_BUY,
                      sellStopOrders, sellStopCount)
   
   IF sellCount > 0 AND buyCount == 0:
      int halfGrid = GridOrders / 2
      IF sellCount > halfGrid:
         GradualClose(sellPositions, sellCount, POSITION_TYPE_SELL,
                      buyStopOrders, buyStopCount)

   // ============================================
   // STEP 8: Gap-filling Migration (single direction, enabled)
   // ============================================
   IF EnableMigration:
      // Re-collect after any gradual closes
      CollectAndSortPositions(buyPositions, sellPositions)
      CollectAndSortPendingOrders(buyStopOrders, sellStopOrders)
      buyCount      = ArraySize(buyPositions)
      sellCount     = ArraySize(sellPositions)
      buyStopCount  = ArraySize(buyStopOrders)
      sellStopCount = ArraySize(sellStopOrders)
      
      IF buyCount > 0 AND sellCount == 0:
         MigrateToFillGaps(DIRECTION_UP, buyPositions, buyCount,
                           buyStopOrders, sellStopOrders, buyStopCount, sellStopCount)
      
      IF sellCount > 0 AND buyCount == 0:
         MigrateToFillGaps(DIRECTION_DOWN, sellPositions, sellCount,
                           buyStopOrders, sellStopOrders, buyStopCount, sellStopCount)

   // ============================================
   // STEP 9: Update chart display
   // ============================================
   UpdateChartInfo(buyCount, sellCount, buyStopCount, sellStopCount, 
                   totalProfit, targetProfit, "ACTIVE")
```

---

## 10. BASKET CLOSE LOGIC (Triple Close)

This is the heart of the strategy.

```
PROCEDURE TryBasketClose(buyPositions[], sellPositions[], buyCount, sellCount,
                         buyStopOrders[], sellStopOrders[], buyStopCount, sellStopCount):

   double requiredProfitMoney = PointsToMoney(GridSpacingPoints, g_sessionLotSize)

   // -----------------------------------------------------------------
   // SCENARIO A: Price is RISING
   // BUY positions are winning, SELL positions are losing
   // Close: Lowest Sell (by price) + Lowest 2 Buys (by price)
   // -----------------------------------------------------------------
   IF buyCount >= 2 AND sellCount >= 1:
      
      // Arrays sorted ASCENDING by price
      SOrderInfo loserSell   = sellPositions[0]         // lowest price sell = most losing
      SOrderInfo winnerBuy1  = buyPositions[0]           // lowest price buy
      SOrderInfo winnerBuy2  = buyPositions[1]           // second lowest price buy
      
      double combinedProfit = loserSell.profit + winnerBuy1.profit + winnerBuy2.profit
      
      IF combinedProfit >= requiredProfitMoney:
         
         // STEP 1: Record the 3 closing prices BEFORE closing
         double closedPrice1 = loserSell.price
         double closedPrice2 = winnerBuy1.price
         double closedPrice3 = winnerBuy2.price
         
         // STEP 2: Determine which Buy is MORE profitable for CloseBy
         // CloseBy: MOST profitable Buy closes against the losing Sell
         // Other Buy: normal close
         ulong closeByBuyTicket, normalCloseBuyTicket
         IF winnerBuy1.profit >= winnerBuy2.profit:
            closeByBuyTicket    = winnerBuy1.ticket
            normalCloseBuyTicket = winnerBuy2.ticket
         ELSE:
            closeByBuyTicket    = winnerBuy2.ticket
            normalCloseBuyTicket = winnerBuy1.ticket
         
         // STEP 3: Migrate 3 farthest SELL STOP orders to the 3 closed prices
         // Do this BEFORE closing to ensure we have valid price references
         // sellStopOrders[] sorted ASCENDING: index 0 = lowest price = farthest when price is up
         IF sellStopCount >= 3:
            ModifyPendingOrder(sellStopOrders[0].ticket, closedPrice1)
            ModifyPendingOrder(sellStopOrders[1].ticket, closedPrice2)
            ModifyPendingOrder(sellStopOrders[2].ticket, closedPrice3)
         
         // STEP 4: Execute closes
         trade.PositionCloseBy(closeByBuyTicket, loserSell.ticket)
         Sleep(200)
         trade.PositionClose(normalCloseBuyTicket)
         
         RETURN

   // -----------------------------------------------------------------
   // SCENARIO B: Price is FALLING
   // SELL positions are winning, BUY positions are losing
   // Close: Highest Buy (by price) + Highest 2 Sells (by price)
   // -----------------------------------------------------------------
   IF sellCount >= 2 AND buyCount >= 1:
      
      SOrderInfo loserBuy    = buyPositions[buyCount - 1]         // highest price buy = most losing
      SOrderInfo winnerSell1 = sellPositions[sellCount - 1]       // highest price sell
      SOrderInfo winnerSell2 = sellPositions[sellCount - 2]       // second highest price sell
      
      double combinedProfit = loserBuy.profit + winnerSell1.profit + winnerSell2.profit
      
      IF combinedProfit >= requiredProfitMoney:
         
         // STEP 1: Record prices
         double closedPrice1 = loserBuy.price
         double closedPrice2 = winnerSell1.price
         double closedPrice3 = winnerSell2.price
         
         // STEP 2: Most profitable Sell for CloseBy
         ulong closeBySellTicket, normalCloseSellTicket
         IF winnerSell1.profit >= winnerSell2.profit:
            closeBySellTicket    = winnerSell1.ticket
            normalCloseSellTicket = winnerSell2.ticket
         ELSE:
            closeBySellTicket    = winnerSell2.ticket
            normalCloseSellTicket = winnerSell1.ticket
         
         // STEP 3: Migrate 3 farthest BUY STOP orders to the 3 closed prices
         // buyStopOrders[] sorted ASCENDING: last indices = highest = farthest when price is down
         IF buyStopCount >= 3:
            ModifyPendingOrder(buyStopOrders[buyStopCount - 1].ticket, closedPrice1)
            ModifyPendingOrder(buyStopOrders[buyStopCount - 2].ticket, closedPrice2)
            ModifyPendingOrder(buyStopOrders[buyStopCount - 3].ticket, closedPrice3)
         
         // STEP 4: Execute closes
         trade.PositionCloseBy(closeBySellTicket, loserBuy.ticket)
         Sleep(200)
         trade.PositionClose(normalCloseSellTicket)
         
         RETURN
```

### CRITICAL NOTES ON BASKET CLOSE:
```
1. Migration happens BEFORE closing — to capture exact prices while positions still exist
2. 3 farthest pending orders of the LOSER'S TYPE get moved to the 3 closed position prices
3. Why loser's type? 
   - Closed 1 Sell (loser) + 2 Buys (winners) → migrate 3 Sell Stops to those prices
   - Closed 1 Buy (loser) + 2 Sells (winners) → migrate 3 Buy Stops to those prices
4. CloseBy pairs the MOST PROFITABLE winner with the loser (saves spread)
5. Number of pending orders stays constant (3 moved, not added/removed)
6. Only ONE basket close per tick — return immediately after to reprocess
```

---

## 11. GRADUAL CLOSE (Single Direction Overflow)

When all open positions are in ONE direction and count exceeds half of GridOrders:

```
PROCEDURE GradualClose(positions[], posCount, posType,
                       oppositeStopOrders[], oppositeStopCount):
   
   int halfGrid = GridOrders / 2
   
   // Only close if count exceeds half grid
   IF posCount <= halfGrid: RETURN
   
   // Close ONE position per tick — the MOST PROFITABLE one
   
   // Find the most profitable position
   int mostProfitableIdx = 0
   double maxProfit = positions[0].profit
   FOR i = 1 TO posCount - 1:
      IF positions[i].profit > maxProfit:
         maxProfit = positions[i].profit
         mostProfitableIdx = i
   
   // Only close if it's actually profitable
   IF maxProfit <= 0: RETURN
   
   // Record the closing price BEFORE closing
   double closedPrice = positions[mostProfitableIdx].price
   ulong closedTicket = positions[mostProfitableIdx].ticket
   
   // Migrate ONE opposite pending order to the closed price
   // Take the FARTHEST opposite pending order
   IF oppositeStopCount > 0:
      ulong migrateTicket
      IF posType == POSITION_TYPE_BUY:
         // Positions are BUY, opposite pending = Sell Stops
         // Farthest Sell Stop = lowest price = index 0 (sorted ascending)
         migrateTicket = oppositeStopOrders[0].ticket
      ELSE:
         // Positions are SELL, opposite pending = Buy Stops
         // Farthest Buy Stop = highest price = last index (sorted ascending)
         migrateTicket = oppositeStopOrders[oppositeStopCount - 1].ticket
      
      ModifyPendingOrder(migrateTicket, closedPrice)
   
   // Now close the position
   trade.PositionClose(closedTicket)
   
   Print("Gradual close: ticket=", closedTicket, " price=", closedPrice, 
         " profit=", maxProfit, " Migrated opposite pending to same price.")
```

### GRADUAL CLOSE RULES:
```
1. ONLY activates when all positions are in ONE direction (no mixed BUY+SELL)
2. ONLY when position count > GridOrders / 2
3. Closes exactly ONE position per tick — the most profitable
4. Migrates ONE farthest opposite pending order to the closed position's price
5. Repeats every tick until count <= GridOrders / 2
6. Example with GridOrders=100:
   - 51 BUY positions → close 1 most profitable BUY → migrate 1 Sell Stop to its price → 50 BUYs
   - Next tick: 52 BUYs (new one activated) → close 1 → migrate 1 → 51 → close 1 → 50
```

---

## 12. FULL CLOSE & RESTART PROCEDURE

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
   
   // === STEP 2: Hedge to neutral ===
   double diff = MathAbs(totalBuyLots - totalSellLots)
   diff = MathCeil(diff / g_lotStep) * g_lotStep
   diff = NormalizeDouble(diff, 2)
   
   IF diff > 0:
      IF totalBuyLots > totalSellLots:
         trade.Sell(diff, _Symbol, 0, 0, 0, "Hedge to neutral")
      ELSE IF totalSellLots > totalBuyLots:
         trade.Buy(diff, _Symbol, 0, 0, 0, "Hedge to neutral")
      Sleep(500)
   
   // === STEP 3: Delete ALL pending orders ===
   DeleteAllPendingOrders()
   Sleep(500)
   
   // === STEP 4: Close all positions via CloseBy ===
   SOrderInfo allBuys[], allSells[]
   CollectAndSortPositions(allBuys, allSells)
   
   int bCount = ArraySize(allBuys)
   int sCount = ArraySize(allSells)
   
   int pairs = MathMin(bCount, sCount)
   FOR i = 0 TO pairs - 1:
      trade.PositionCloseBy(allBuys[i].ticket, allSells[i].ticket)
      Sleep(200)
   
   // === STEP 5: Close any remainders ===
   CloseAllRemainingPositions()
   
   // === STEP 6: Reset state ===
   g_gridInitialized = false
   g_anchorPrice = 0
   g_sessionLotSize = 0
   g_marketCloseMode = false
   
   Print("=== CYCLE COMPLETE === Profit target reached. Restarting...")
```

---

## 13. ORDER REPLENISHMENT

```
PROCEDURE ReplenishPendingOrders(buyStopOrders[], sellStopOrders[], 
                                  buyStopCount, sellStopCount):
   
   // Expected pending orders per side = GridOrders (constant)
   
   // --- Replenish Buy Stops ---
   int missingBuyStops = GridOrders - buyStopCount
   
   IF missingBuyStops > 0:
      double highestBuyStopPrice = 0
      IF buyStopCount > 0:
         highestBuyStopPrice = buyStopOrders[buyStopCount - 1].price
      ELSE:
         highestBuyStopPrice = GetHighestPositionPrice(POSITION_TYPE_BUY)
      
      FOR i = 1 TO missingBuyStops:
         double newPrice = highestBuyStopPrice + (i * GridSpacingPoints * g_point)
         newPrice = NormalizeDouble(newPrice, g_digits)
         
         double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK)
         IF newPrice > ask + g_stopLevel * g_point:
            PlacePendingOrder(ORDER_TYPE_BUY_STOP, newPrice, g_sessionLotSize)
   
   // --- Replenish Sell Stops ---
   int missingSellStops = GridOrders - sellStopCount
   
   IF missingSellStops > 0:
      double lowestSellStopPrice = DBL_MAX
      IF sellStopCount > 0:
         lowestSellStopPrice = sellStopOrders[0].price
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

## 14. GAP-FILLING MIGRATION

Fills gaps between Buy and Sell orders when only one direction of market orders exists. Also handles gaps caused by Freeze Level.

```
PROCEDURE MigrateToFillGaps(direction, marketPositions[], posCount,
                             buyStopOrders[], sellStopOrders[], 
                             buyStopCount, sellStopCount):
   
   IF direction == DIRECTION_UP:
      // Only BUY positions exist, price is going up
      // Move farthest (lowest) Sell Stops up to fill gap
      
      IF sellStopCount == 0 OR posCount == 0: RETURN
      
      double lowestBuyPos = marketPositions[0].price
      double lowestBuyStop = (buyStopCount > 0) ? buyStopOrders[0].price : lowestBuyPos
      double highestSellStop = sellStopOrders[sellStopCount - 1].price
      
      double gapTop = MathMin(lowestBuyPos, lowestBuyStop)
      double gapBottom = highestSellStop
      
      IF gapTop - gapBottom <= GridSpacingPoints * g_point * 2: RETURN
      
      int slotsAvailable = (int)MathFloor((gapTop - gapBottom) / (GridSpacingPoints * g_point)) - 1
      IF slotsAvailable <= 0: RETURN
      
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
      // Move farthest (highest) Buy Stops down to fill gap
      
      IF buyStopCount == 0 OR posCount == 0: RETURN
      
      double highestSellPos = marketPositions[posCount - 1].price
      double highestSellStop = (sellStopCount > 0) ? sellStopOrders[sellStopCount - 1].price : highestSellPos
      double lowestBuyStop = buyStopOrders[0].price
      
      double gapBottom = MathMax(highestSellPos, highestSellStop)
      double gapTop = lowestBuyStop
      
      IF gapTop - gapBottom <= GridSpacingPoints * g_point * 2: RETURN
      
      int slotsAvailable = (int)MathFloor((gapTop - gapBottom) / (GridSpacingPoints * g_point)) - 1
      IF slotsAvailable <= 0: RETURN
      
      int ordersToMove = MathMin(slotsAvailable, buyStopCount)
      
      FOR i = 0 TO ordersToMove - 1:
         int idx = buyStopCount - 1 - i
         double targetPrice = gapBottom + ((i + 1) * GridSpacingPoints * g_point)
         targetPrice = NormalizeDouble(targetPrice, g_digits)
         
         double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK)
         IF targetPrice > ask + g_stopLevel * g_point:
            IF MathAbs(buyStopOrders[idx].price - targetPrice) > g_point:
               ModifyPendingOrder(buyStopOrders[idx].ticket, targetPrice)
```

---

## 15. UTILITY FUNCTIONS

### 15.1 Points to Money
```
FUNCTION PointsToMoney(points, lots) -> double:
   RETURN points * g_tickValue / g_tickSize * lots * g_point
```

### 15.2 Place Pending Order
```
FUNCTION PlacePendingOrder(orderType, price, lots) -> bool:
   price = NormalizeDouble(price, g_digits)
   
   FOR retry = 0 TO 2:
      bool result = false
      IF orderType == ORDER_TYPE_BUY_STOP:
         result = trade.BuyStop(lots, price, _Symbol, 0, 0, ORDER_TIME_GTC, 0, "GridEA BuyStop")
      ELSE IF orderType == ORDER_TYPE_SELL_STOP:
         result = trade.SellStop(lots, price, _Symbol, 0, 0, ORDER_TIME_GTC, 0, "GridEA SellStop")
      
      IF result: RETURN true
      
      uint error = trade.ResultRetcode()
      Print("PlacePendingOrder failed: ", trade.ResultRetcodeDescription(), " Price=", price)
      
      IF error == TRADE_RETCODE_INVALID_STOPS OR error == TRADE_RETCODE_INVALID_PRICE:
         IF orderType == ORDER_TYPE_BUY_STOP:
            price = SymbolInfoDouble(_Symbol, SYMBOL_ASK) + (g_stopLevel + 5) * g_point
         ELSE:
            price = SymbolInfoDouble(_Symbol, SYMBOL_BID) - (g_stopLevel + 5) * g_point
         price = NormalizeDouble(price, g_digits)
      
      Sleep(300)
   
   RETURN false
```

### 15.3 Modify Pending Order
```
FUNCTION ModifyPendingOrder(ticket, newPrice) -> bool:
   newPrice = NormalizeDouble(newPrice, g_digits)
   
   FOR retry = 0 TO 2:
      IF !OrderSelect(ticket): RETURN false
      
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK)
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID)
      int ordType = (int)OrderGetInteger(ORDER_TYPE)
      
      // Check stop level
      IF ordType == ORDER_TYPE_BUY_STOP:
         IF newPrice <= ask + g_stopLevel * g_point:
            Print("ModifyPendingOrder: price too close to Ask. Skipping.")
            RETURN false
      ELSE IF ordType == ORDER_TYPE_SELL_STOP:
         IF newPrice >= bid - g_stopLevel * g_point:
            Print("ModifyPendingOrder: price too close to Bid. Skipping.")
            RETURN false
      
      // Check freeze level
      double currentOrderPrice = OrderGetDouble(ORDER_PRICE_OPEN)
      IF ordType == ORDER_TYPE_BUY_STOP:
         IF MathAbs(currentOrderPrice - ask) <= g_freezeLevel * g_point:
            Print("ModifyPendingOrder: order within freeze level. Skipping.")
            RETURN false
      ELSE IF ordType == ORDER_TYPE_SELL_STOP:
         IF MathAbs(currentOrderPrice - bid) <= g_freezeLevel * g_point:
            Print("ModifyPendingOrder: order within freeze level. Skipping.")
            RETURN false
      
      bool result = trade.OrderModify(ticket, newPrice, 0, 0, ORDER_TIME_GTC, 0)
      IF result: RETURN true
      
      Print("ModifyPendingOrder failed: ", trade.ResultRetcodeDescription())
      Sleep(300)
   
   RETURN false
```

### 15.4 Collect and Sort Positions
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
   
   SortByPriceAscending(buyPositions)
   SortByPriceAscending(sellPositions)
```

### 15.5 Collect and Sort Pending Orders
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

### 15.6 Sort by Price
```
FUNCTION SortByPriceAscending(&arr[]):
   int n = ArraySize(arr)
   FOR i = 0 TO n - 2:
      FOR j = 0 TO n - 2 - i:
         IF arr[j].price > arr[j+1].price:
            SOrderInfo temp = arr[j]
            arr[j] = arr[j+1]
            arr[j+1] = temp
```

### 15.7 Calculate Total Floating Profit
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

### 15.8 Delete All Pending Orders
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

### 15.9 Close All Remaining Positions
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

### 15.10 Get Highest/Lowest Position Price
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
   FOR i = 0 TO PositionsTotal() - 1:
      ulong ticket = PositionGetTicket(i)
      IF PositionGetString(POSITION_SYMBOL) != _Symbol: CONTINUE
      IF PositionGetInteger(POSITION_MAGIC) != MagicNumber: CONTINUE
      IF PositionGetInteger(POSITION_TYPE) != posType: CONTINUE
      double price = PositionGetDouble(POSITION_PRICE_OPEN)
      IF price < lowest: lowest = price
   RETURN lowest
```

---

## 16. CHART DISPLAY

```
PROCEDURE UpdateChartInfo(buyCount, sellCount, buyStopCount, sellStopCount, 
                           totalProfit, targetProfit, status):
   
   double balance = AccountInfoDouble(ACCOUNT_BALANCE)
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY)
   double progress = (targetProfit > 0) ? (totalProfit / targetProfit * 100.0) : 0
   double drawdown = (balance > 0) ? ((balance - equity) / balance * 100.0) : 0
   
   string info = ""
   info += "╔══════════════════════════════════════╗\n"
   info += "║       GRID HEDGE EA v3.0             ║\n"
   info += "╠══════════════════════════════════════╣\n"
   info += "║ Status:       " + status + "\n"
   info += "║ Anchor Price: " + DoubleToString(g_anchorPrice, g_digits) + "\n"
   info += "║ Session Lot:  " + DoubleToString(g_sessionLotSize, 2) + "\n"
   info += "║ Grid Spacing: " + IntegerToString((int)GridSpacingPoints) + " pts\n"
   info += "║ Half Grid:    " + IntegerToString(GridOrders / 2) + "\n"
   info += "╠══════════════════════════════════════╣\n"
   info += "║ BUY Positions:   " + IntegerToString(buyCount) + "\n"
   info += "║ SELL Positions:  " + IntegerToString(sellCount) + "\n"
   info += "║ Buy Stops:       " + IntegerToString(buyStopCount) + "\n"
   info += "║ Sell Stops:      " + IntegerToString(sellStopCount) + "\n"
   info += "║ Total Orders:    " + IntegerToString(buyCount + sellCount + buyStopCount + sellStopCount) + "\n"
   info += "╠══════════════════════════════════════╣\n"
   info += "║ Floating P/L:  $" + DoubleToString(totalProfit, 2) + "\n"
   info += "║ Target (" + DoubleToString(TotalProfitPercent, 1) + "%): $" + DoubleToString(targetProfit, 2) + "\n"
   info += "║ Progress:      " + DoubleToString(progress, 1) + "%\n"
   info += "╠══════════════════════════════════════╣\n"
   info += "║ Balance:  $" + DoubleToString(balance, 2) + "\n"
   info += "║ Equity:   $" + DoubleToString(equity, 2) + "\n"
   info += "║ Drawdown: " + DoubleToString(drawdown, 1) + "%\n"
   info += "╠══════════════════════════════════════╣\n"
   info += "║ Migration:    " + (EnableMigration ? "ON" : "OFF") + "\n"
   info += "║ Market Close: " + (g_marketCloseMode ? "ACTIVE" : "Normal") + "\n"
   info += "╚══════════════════════════════════════╝\n"
   
   Comment(info)
```

---

## 17. OnDeinit

```
PROCEDURE OnDeinit(const int reason):
   Comment("")
   Print("Grid Hedge EA removed. Reason: ", reason)
   // Do NOT close positions or delete orders on deinit
   // User may want to restart EA and resume
```

---

## 18. ERROR HANDLING RULES

```
ALL trade operations MUST:
1. Check return value after every call
2. Retry up to 3 times with Sleep(200-500ms)
3. Handle specific errors:
   - TRADE_RETCODE_REQUOTE        → Refresh rates, retry
   - TRADE_RETCODE_REJECT         → Wait 500ms, retry
   - TRADE_RETCODE_ERROR          → Log and skip
   - TRADE_RETCODE_TIMEOUT        → Wait 1000ms, retry
   - TRADE_RETCODE_INVALID_STOPS  → Adjust price, retry
   - TRADE_RETCODE_TOO_MANY_REQUESTS → Wait 2000ms, retry
   - TRADE_RETCODE_NO_MONEY       → Log critical warning, skip
4. Log all errors with function name, error code, price, ticket
5. After CloseBy: always Sleep(200) before next operation
```

---

## 19. COMPLETE EXECUTION FLOW

```
[EA START]
    │
    ▼
[OnInit] → Cache symbol info → Check hedging → Check existing grid
    │
    ├─ (Existing grid) ──► Resume
    ├─ (Market close time) ──► g_waitingForNewDay = true
    └─ (Fresh start) ──► InitializeGrid()
                           │
                           ├─ Calculate anchor & grid levels
                           ├─ Place Buy Stops: FARTHEST (highest) → nearest
                           │    └─ If blocked → relocate remaining to top
                           ├─ Place Sell Stops: FARTHEST (lowest) → nearest
                           │    └─ If blocked → relocate remaining to bottom
                           └─ Gaps filled on next tick by Replenish + Migrate
    │
    ▼
[OnTick] ◄──────────────────────────────────────────────
    │
    ├─ [Waiting for new day?] ──YES──► Check if new day → InitializeGrid() → RETURN
    │
    ▼
[Market Close Protection active?]
    │
    ├─ YES ──► [No positions?] ──► Delete pendings, wait for new day
    │          [Has positions?] ──► [P/L >= 0?] ──YES──► Full close, wait for new day
    │                               └─ NO ──► Keep monitoring, RETURN
    ▼ NO
[Total Profit >= X%?] ──YES──► Hedge→Delete→CloseBy→Restart
    │
    ▼ NO
[Replenish pending orders (fill far end)]
    │
    ▼
[Both BUY and SELL exist?]
    │
    ├─ YES ──► [Basket Close: 1 loser + 2 winners]
    │            1. Record 3 prices
    │            2. Migrate 3 farthest opposite pendings to those prices
    │            3. CloseBy (most profitable winner vs loser)
    │            4. Normal close (other winner)
    │            RETURN
    │
    ▼ NO (single direction)
[Count > Half Grid?]
    │
    ├─ YES ──► [Gradual Close: close 1 most profitable]
    │            Migrate 1 opposite pending to closed price
    │
    ▼
[Gap-filling Migration] (if enabled)
    │ Fill gaps between Buy/Sell zones with opposite pendings
    │
    ▼
[Update Chart Display]
    │
    ▼
[Next tick] ──────────────────────────────► [OnTick]
```

---

## 20. OUTPUT REQUIREMENTS

1. **Single .mq5 file** — complete, compilable, production-ready
2. **All functions fully implemented** — no stubs, no pseudocode, no TODOs
3. **Well-commented code** — header comment for each function
4. **Use CTrade, CPositionInfo, COrderInfo** from standard library
5. **Input parameters** exactly as specified in Section 2
6. **Chart display** as specified in Section 16
7. **Error handling** on every trade operation per Section 18
8. **Hedging account check** in OnInit
9. **Market close protection** with auto-restart next day
10. **Gradual close** when single-direction count exceeds half grid
11. **OrderCloseBy** used for basket close AND full close

---

## 21. TESTING CHECKLIST

- [ ] Grid places correct number of orders on both sides of anchor
- [ ] Grid placement uses far-to-near order: Buy Stops from highest→lowest, Sell Stops from lowest→highest
- [ ] When placement is interrupted (price catches up / freeze zone), remaining orders relocate to far end
- [ ] Total order count per side always equals GridOrders after init (no missing orders)
- [ ] No "invalid price" or "rejected" errors during initialization
- [ ] Gaps near price created during init are filled by Replenish + Migrate on next tick
- [ ] Anchor = (Ask+Bid)/2, fixed until restart
- [ ] Lot size calculated for 4000 orders margin, fixed during session
- [ ] Pending orders replenished at far end when activated
- [ ] Basket close: correct 3 positions (1 loser + 2 winners by price)
- [ ] CloseBy pairs MOST PROFITABLE winner with loser
- [ ] After basket close: 3 farthest pendings of LOSER's type migrate to closed prices
- [ ] Migration happens BEFORE closing
- [ ] Gradual close: triggers when single-direction count > GridOrders/2
- [ ] Gradual close: closes 1 most profitable per tick, migrates 1 opposite pending
- [ ] Gap-filling: moves farthest opposite pendings to fill gaps
- [ ] Total profit target: hedge→delete→CloseBy→restart
- [ ] Market close protection: no new orders, close at breakeven
- [ ] Auto-restart next trading day with fresh grid
- [ ] Freeze level respected in all order modifications
- [ ] All trade operations have retry + error handling
- [ ] Works on any symbol (forex, crypto, gold, indices)
