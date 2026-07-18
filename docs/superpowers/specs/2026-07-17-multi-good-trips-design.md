# Multi-good trips

**Date:** 2026-07-17  
**Status:** Implemented (undeployed trading; clean break OK)  
**App:** FullCircle  

## Decision

Product lives on **each load and drop line** (`good_id`), not on the trip header. One trip can mix goods, sources, and sales orders.

## Schema

- `trading_trip_loads.good_id` — required  
- `trading_trip_drops.good_id` — required  
- `trading_trips.good_id` — **removed**

Validation: each line’s `good_id` must match linked supply/sales when present.

Warehouse balances group by **line** `good_id`.

## Desk assembly

- No good lock — multi-good checkbox selection allowed  
- `build_trip_attrs_from_selection/3` sets `good_id` on every load/drop  
- Create Trip still requires ≥1 source and ≥1 sales  

## UI

- Trip form: good select per load/drop (auto-filled from supply/sales when chosen)  
- Trip lists: goods joined as “Maize, Pollard”  
