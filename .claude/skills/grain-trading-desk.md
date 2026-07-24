---
name: grain-trading-desk
description: Use when working on FullCircle grain trading — SupplyPosition, SalesPosition, Trip (loads/drops), Location GPS, warehouse board, desk assembly, balances, system doc nos (SUP/SAL/TRP), or trading LiveViews under trading_desk_live / trading_*.
---

# Grain Trading Desk

Domain knowledge for `lib/full_circle/trading.ex`, `lib/full_circle/trading/*`, and
desk UI under `lib/full_circle_web/live/trading_*`. Specs live in
`docs/superpowers/specs/2026-07-15-grain-trading-trip-design.md` and later
desk/multi-good docs (as-built may supersede early non-goals).

## Mental model

| Concept | Role |
|---------|------|
| **SupplyPosition** | Commercial supply deal (vessel, local PO, …). No type enum. |
| **SalesPosition** | Customer commitment. Soft-hold via optional `preferred_supply`. |
| **Location** | Physical site (port / supplier_site / customer_site / own_warehouse / other). Optional GPS. |
| **Trip** | Haul with multi-load + multi-drop; multi-good on **lines**, not header. |
| **Balances** | Remaining / undelivered / warehouse on-hand only from **completed** trips. |

Settlement Invoice / PurInvoice stay in finance — trading does not auto-post them.
**Settlement** (`/trading/settlement`):
- **Phase A (customer):** sales drops → Invoice → `trip_drops.invoice_id`
- **Phase B (supplier):** commercial loads → PurInvoice → `trip_loads.pur_invoice_id`
Gate for billing is trip `completed` only (draft/planned shown, not selectable).
See `docs/superpowers/specs/2026-07-23-trading-settlement-invoicing-design.md`.

## Status machines

**Supply** (`open | hold | collect | closed`):

- `open` — no collection date yet (still loadable)
- `hold` — supplier pauses collection
- `collect` — supplier allows collection
- `closed` — stock finished

Active board / soft-hold targets: `open | hold | collect`.  
Loading a supply that is still `open` **auto-promotes to `collect`** on trip create/update.

**Sales** (`draft | open | hold | fulfilled | cancelled`):

- Active (open board / soft hold / drop targets): `draft | open | hold`
- Terminal: `fulfilled` (may be short; optional `fulfilled_note`), `cancelled`

**Trip** (`draft | planned | completed | cancelled`):

- Completed/cancelled trips are **locked** (`{:error, :trip_locked}` on update)
- Complete requires `actual_mt` on every load and drop; returns `{:ok, trip, warnings}` — warnings never block

## System document numbers

Gapless per company via `gapless_doc_ids`:

| Entity | Prefix | Field |
|--------|--------|-------|
| Supply | `SUP-` | `title` (unique per company) |
| Sales | `SAL-` | `title` (unique per company) |
| Trip | `TRP-` | `reference_no` (immutable after create) |

Unit always comes from **Good** — never stored on positions.

## Balances (`Trading.Balances`)

- **Physical stock movement** only counts trips with `status == "completed"`.
- **Soft hold** = sum of undelivered qty on active sales that prefer a supply — **display only**, does not lock remaining.
- **In transit** (draft + planned) uses `coalesce(actual_mt, planned_mt)` so desks show commitment without moving stock.
- Warehouse on-hand groups by **own_warehouse** location × **line** `good_id`.

## Multi-good trips

Product lives on each **TripLoad / TripDrop** (`good_id` required). Trip header has no `good_id`.
Line `good_id` must match linked supply/sales when present. Desk assembly allows mixed goods.

## Desk assembly (`build_trip_attrs_from_selection/3`)

Selection map (string or atom keys):

- `:supply_ids` — commercial loads
- `:warehouse_load_keys` — own warehouse **out** (`%{location_id, good_id}`)
- `:warehouse_drop_keys` — own warehouse **in** (`%{location_id, good_id | nil}`)
- `:sales_ids` — customer drops

Unified: loads = supplies + warehouse out; drops = sales + warehouse in.  
Requires ≥1 load and ≥1 drop line.

## Locations & GPS

Kinds: `port | supplier_site | customer_site | own_warehouse | other`.  
Optional `latitude`/`longitude` (WGS84) — both or neither.  
`Location.google_maps_url/1` is derived, not stored.  
Form: click-to-set map (default satellite) + place search to zoom.

On **new supply**, `ensure_supplier_site_location/3` auto-creates a `supplier_site`
Location for the supplier if none exists. Mirror for customers:
`ensure_customer_delivery_location/3`.

Drivers are **Employees**; transport agents are **Contacts**. Agent required only when
`transport_mode == "agent"`. Modes: `company_own | agent | customer_arranged`.

Multi-employee on load/drop via `trip_load_employees` / `trip_drop_employees`.

## Desk-only UX

Primary route: `/companies/:id/trading/desk` (`TradingDeskLive.Index`).

Legacy paths (`position_board`, `warehouse_board`, `open_sales`, supply/sales/trips
list/new/edit) **redirect into the desk** with modal live actions
(`:new_supply`, `:edit_trip`, …).

Components: `supply_form_component`, `sales_form_component`, `trip_form_component`
on the desk; print under `trading_trip_live`, `trading_sales_live`,
`trading_history_live`.

## Auth

- `:view_trading` — boards, lists, print
- `:manage_trading` — create/update/complete/cancel

## Gotchas

1. **Warn-only oversell** — remaining can go negative; `trip_warnings/1` is advisory.
2. **Title uniqueness** — SUP/SAL titles unique per company; do not free-edit after create without care (trip ref never changes).
3. **Loadable open supplies** — open is intentionally loadable and promotes to collect; do not treat open as non-loadable.
4. **Sample data** — `Trading.SampleData` for demo seed; not production.
5. **Order/Load/Delivery removed** from Product — trading replaced that logistics path for grain.
6. **Migrations collapsed** for undeployed trading schema; prefer current schemas over intermediate migration history.

## Key files

```
lib/full_circle/trading.ex
lib/full_circle/trading/{supply_position,sales_position,trip,trip_load,trip_drop,
  trip_load_employee,trip_drop_employee,location,balances,sample_data}.ex
lib/full_circle_web/live/trading_desk_live/
lib/full_circle_web/live/trading_components.ex
lib/full_circle_web/live/trading_{location,trip,sales,history}_live/
test/full_circle/trading/
```
