# Trading warehouse stock adjustment — design

**Date:** 2026-10-01 · **Status:** approved (physical only; admin + manager)

## Problem

Own-warehouse on-hand is derived: completed trip drops in − completed trip loads
out, per location × good. There is no way to correct it after a stocktake
(shrinkage, moisture loss, spillage) or to enter opening stock.

## Decision

A new immutable movement, `Trading.StockAdjustment` (`trading_stock_adjustments`),
entered as a **stocktake**: the user types the *counted* qty; the system stores
the signed difference against the current book on-hand.

- Columns: `company_id`, `location_id` (must be an `own_warehouse` of the
  company), `good_id`, `adjust_date`, `reference_no` (gapless `ADJ-######`,
  doc type `TradingStockAdj`), `system_qty` (book on-hand at entry),
  `counted_qty`, `qty` (= counted − system, never 0), `reason` (required),
  `created_by_id`.
- **Physical only** — no GL posting, like trips.
- **Immutable** — no edit, no delete. A wrong count is fixed by entering
  another stocktake with the right count (it records the correcting delta).
  Keeps the ADJ series gapless and the history honest.
- **Permission** `:adjust_trading_stock` — admin, manager.
- Book on-hand is not date-filtered today, so `system_qty` is the on-hand at
  the moment of entry (all completed trips + earlier adjustments);
  `adjust_date` is informational/for history ordering.

## Balances

`on_hand = completed drops − completed loads + Σ adjustments.qty`.
`Balances.own_warehouse_adjusted_by_good/1` (one `GROUP BY`) feeds
`warehouse_board/2` (adds an `adjusted` field; adjustment-only location × good
pairs get a row) and `Balances.own_warehouse_on_hand/2`, which replaces the
private `warehouse_on_hand/2` in desk assembly. `own_warehouse_qty/1` includes
adjustments.

## UI

In the desk's warehouse history modal (one location × good):

- adjustments appear as `Adj` rows (reference no, signed qty, reason; not
  clickable — there is no trip to open);
- admins/managers get an **Adjust stock** form (date default today, counted
  qty, reason) showing the live difference vs book; Save refreshes the board
  and the modal.
