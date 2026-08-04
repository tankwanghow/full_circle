---
name: grain-trading-desk
description: Use when working on FullCircle grain trading — SupplyPosition, SalesPosition, Trip (loads/drops), Location GPS, warehouse board, desk assembly, balances, system doc nos (SUP/SAL/TRP), trading LiveViews under trading_desk_live / trading_*, or linking a PurInvoice (including one keyed from a received e-invoice) to trading settlement.
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
- **Phase C (transport):** agent haul lines (drop + origin) → PurInvoice →
  `trip_drops.transport_pur_invoice_id`; line good priority:
  Transport Services Purchase → Transport Charges → Note
  (else create Haulage); unit price clerk-entered (no rate matrix)
- **Multi-customer trips:** settlement unit is the **drop** (via
  `sales_position.customer_id`), not the trip. One TRP can have drops for
  customers A and B; each invoice only lists/links **that** customer’s drops.
  `list_uninvoiced_drops(..., customer_id:)` and
  `link_drops_to_invoice` (`same_customer?` / `customer_matches_invoice?`) enforce this.
- **Attach (pull) direction — Invoice:**
  `InvoiceLive.TradingAttachComponent` on Invoice new/edit (when not already
  push-linked via `trading_drops=`). Tick uninvoiced drops for the invoice
  contact; save uses `Billing.create_invoice/4` or `update_invoice/5`
  `extend_multi` → `Trading.attach_invoice_drops_multi/5`. Hidden when
  settlement already linked or when opened from the board push flow.
- **Attach (pull) — PurInvoice:** `PurInvoiceLive.TradingAttachComponent` +
  `attach_links_multi/6` (loads + transport).
- **Desk deep-link:** trip row **Settlement** →
  `/trading/settlement?trip_id=<id>` opens a **single-trip page** (not the
  tabbed board): Customer Invoice + Supplier Bill + Transport Bill sections on
  one screen. No tabs, party/date filters, or “show all”. Only **Back to Trading
  Desk** and per-section **Create …** actions. Includes billed + unbilled lines
  (`doc_id` / `doc_no` / `doc_kind` link to Invoice/PurInvoice). Global board
  (`/trading/settlement` without trip_id) still uses tabs/filters and hides settled.
Gate for billing is trip `completed` only (draft/planned shown, not selectable).

**Prefill dates come from the trip, and settle same-day.** All three builders
(`invoice_attrs_from_drops`, and the supplier / transport `pur_invoice_attrs_*`)
date the document `trip.date || Date.utc_today()` and set
**`due_date` == that same date** — trading settles on the trip date, it does not
run payment terms. Don't reintroduce a `Date.add(date, 30)` here.

Note the settlement screen **discards** the attrs it builds and deep-links to
`/Invoice/new?trading_drops=…` (or `?trading_loads=` / `?trading_transport_drops=`);
the receiving form re-runs the same builder. A prefill change must be made in
`Settlement`, not in the LiveView, or the two paths diverge.

## Attach direction (the e-invoice path)

Everything above is **push**: the board builds the document. Most purchase bills
do not arrive that way — supplier and haulier bills come in as received LHDN
e-invoices and are keyed from `/PurInvoice/new?obj=…` through
`EInvMetas.Prefill`, which knows nothing about trading. Without an attach path
those bills leave `trip_loads.pur_invoice_id` / `trip_drops.transport_pur_invoice_id`
nil forever and the trip never goes green. See `e-invoice-bill-prefill.md`.

`PurInvoiceLive.TradingAttachComponent` renders on **any** PurInvoice form (new,
e-invoice-seeded, or edit) once a contact resolves, listing that contact's
unbilled loads and hauls from the existing `list_unbilled_loads/3` /
`list_unbilled_transport_lines/3`. Ticked lines link on save.

- **Primitives:** `Settlement.link_loads_to_pur_invoice/4` and
  `link_transport_drops_to_pur_invoice/4`, mirroring the customer-side
  `link_drops_to_invoice/4`. All reuse the company-scoped eligibility loaders,
  so a client-supplied id cannot reach another company's line.
- **Composition:** `Settlement.attach_links_multi/6` is appended via the
  `extend_multi` argument on `Billing.create_pur_invoice/5` /
  `update_pur_invoice/5`. **That argument exists so Billing carries no Trading
  dependency — don't inline the link steps into Billing.**
- **Hidden on the push flow** (`trading_loads=` / `trading_transport_drops=`
  params present), which already links; otherwise the panel would offer the very
  lines being billed.
- **Selection is keyed to the contact** and dropped if the supplier changes —
  the panel unmounts on that change and cannot retract the ids itself.
- **Variance strip is advisory** and sums quantity across all detail lines, so
  it is only meaningful on a single-good bill. It never blocks.
- Saving with nothing ticked while billable lines exist flashes `:warn`
  (`billable_line_counts/4`). Kind must be `:warn` — `:warning` renders nothing.

**`:loads_already_billed` is nearly unreachable.** The eligibility loaders filter
`is_nil(pur_invoice_id)` first, so a line billed earlier returns
`:ineligible_loads`. The already-billed error only fires in a true race between
the eligibility read and the `update_all`.

**Link hygiene:** link means “settled via” (not live mirror). While linked, **party
(contact) is locked** on Invoice/PurInvoice; qty/price may still be edited.
**Unlink trading settlement** clears FKs so lines reappear on settlement queues
(no void/delete on finance docs).
**Cancel trip:** completed trips with any linked Invoice / supplier PurInvoice /
transport PurInvoice return `{:error, :has_invoices}` and the desk hides **Cancel trip**
(`trip_has_settlement_docs?/1`). Unlink settlement first, then cancel if needed.
**Desk trip row (Option C):** one row per trip; completed trips show a second line of
settlement chips (Customer / Supplier / Transport). Chevron expands load/drop lines
inline (still one trip, not split into multi rows).
**Desk trips panel:** `trips_panel` assign `:shown` (default ~28% height) | `:hidden`
(header only) | `:maximized` (hides supply/warehouse/sales, trips fill remaining height).
Controls: Show / Hide / Maximize / Restore on the trips header.
**Column filters:** comma-separated tokens are **OR** (trimmed, case-insensitive
substring). Status boxes show defaults on mount:
- Supplies: `open, hold, collect`
- Sales: `draft, open, hold`
- Trips: `draft, planned`

**Auto good filter:** selecting sales rows writes the unique good names of the
selection (comma-OR) into the **supply** and **warehouse** `good` column filters
(`sync_good_filters_from_selected_sales/1`). Clearing the selection or creating
the trip clears them again — these filters are derived, not user-owned.

**Trip bill filters:** sticky chips under trips header — **Needs bill** /
**Cust unbilled** / **Supp unbilled** / **Haul unbilled** (multi-select OR on
`trip_settlement_badges` open|partial). Mount is **ops-first**: Bill chips off.
Turning a Bill chip on forces trip status `completed`; last chip off restores
`draft, planned`. **Clear** clears chips **and** the trip status box. Title shows
`shown/all` when any filter active.

**The trips panel is loaded two different ways** (`load_trips_for_panel/3`):

| Bill chips | Query | Why |
|---|---|---|
| off | newest 50 (`Enum.take(50)`) | ops view only cares about recent work |
| any on | `list_trips(status: "completed")`, **uncapped** | settlement stays open indefinitely; capping hides old unbilled trips |

Toggling a chip therefore has to **reload** the panel (`reload_trips/1`), not just
re-filter the existing assign. A trip only carries settlement badges at all when
it is `completed` **and** has a `supply_position_id` on a load (supplier stream),
a `sales_position_id` on a drop (customer stream), or `transport_mode == "agent"`
with an agent (transport stream) — otherwise `show?: false` and no chip matches it.
See `docs/superpowers/specs/2026-07-23-trading-settlement-invoicing-design.md`.

## Status machines

**Supply** (`open | hold | collect | closed`):

- `open` — no collection date yet (still loadable)
- `hold` — supplier pauses collection
- `collect` — supplier allows collection
- `closed` — stock finished

Active board / soft-hold targets: `open | hold | collect`.  
Loading a supply that is still `open` **auto-promotes to `collect`** on trip create/update.
That promotion is **not recorded anywhere**, so an auto-promoted `collect` cannot
later be told apart from one a clerk set by hand — see `cancel_trip` below.

**Sales** (`draft | open | hold | fulfilled | cancelled`):

- Active (open board / soft hold / drop targets): `draft | open | hold`
- Terminal: `fulfilled` (may be short; optional `fulfilled_note`), `cancelled`

**Terminal positions are status-locked.** Supply `closed` and sales
`fulfilled`/`cancelled` are terminal (`SupplyPosition.terminal?/1`,
`SalesPosition.terminal?/1`). `update_supply_position` / `update_sales_position`
return `{:error, :position_locked}` for any attempt to move to a *different*
status — including via the thin wrappers (`hold_`, `collect_`, `open_`,
`fulfill_`, `cancel_`). Deliberately surgical:

- Other fields stay editable (e.g. `notes` on a closed supply)
- Re-asserting the *same* terminal status is a no-op, not an error — so
  `fulfill_sales_position` can still revise a `fulfilled_note`

Callers must handle `{:error, :position_locked}`; the desk form components flash
a specific message for it.

**Preferred supply must match the sales good.** Autocomplete is
`schema=opensupply&good_id=<good_id>`; with no good picked yet it passes
`good_id=__none__` so the list stays empty rather than showing everything.
A mismatched supply clears both `preferred_supply_id` and
`preferred_supply_title` — enforced on the good change, on the title change, and
again in save. Display label is `SUP-… · Good · Supplier`.

**Trip** (`draft | planned | completed | cancelled`):

- Completed/cancelled trips are **locked** (`{:error, :trip_locked}` on update)
- **Save never sets `completed`/`cancelled`.** Form status options are only
  `draft`/`planned`; lifecycle is **Complete trip** / **Cancel trip** only.
  `create_trip` / `update_trip` clamp any other status to a writable value.
- **Non-warehouse drops require sales on Save.** Drop location kind
  `own_warehouse` may omit `sales_position_id` (stock-in). Any other kind
  (`customer_site`, `port`, `supplier_site`, `other`) must have a sales
  position or create/update is rejected
  (`sales_position_id: required for non-warehouse drop`). Complete applies
  the same rule as defense in depth.
- Complete requires `actual` on every load and drop **and** ≥1 load + ≥1 drop;
  returns `{:ok, trip, warnings}` — warnings never block.
- Complete rejects customer-site drops without `sales_position_id`
  (`{:error, :customer_drops_need_sales}`) — settlement has no customer path
  otherwise.
- Typeahead re-resolve on save: never wipe `sales_position_id` /
  `supply_position_id` when open-only lookup misses; fall back to any-status
  title lookup (`get_sales_position_by_title` / `get_supply_position_by_title`)
  so fulfill/close then re-save does not unlink lines.
- `cancel_trip` also returns **`{:ok, trip, warnings}`** (same shape as complete).
  A completed trip with a linked Invoice/PurInvoice cannot be cancelled
  (`{:error, :has_invoices}`) — unlink settlement first.

**Cancelling never reverts a supply's `collect` status.** Because the
`open → collect` promotion is not recorded, auto-reverting would wrongly reopen a
supply a clerk had marked `collect` by hand. Instead `stranded_collect_warnings/2`
returns an advisory naming each supply that is still `collect` **and** no longer
referenced by any non-cancelled trip; the clerk decides. Status is left untouched.

## System document numbers

Gapless per company via `gapless_doc_ids`:

| Entity | Prefix | Field |
|--------|--------|-------|
| Supply | `SUP-` | `title` (unique per company) |
| Sales | `SAL-` | `title` (unique per company) |
| Trip | `TRP-` | `reference_no` (immutable after create) |

**Supply no on create:** the desk modal field is editable. If the user leaves it
blank (or the UI placeholder `...new...`), `create_supply_position` assigns the
next gapless `SUP-######`. If they type a value, that trimmed string is stored
as `title` (still unique per company). After create the number is immutable
(`update_supply_position` always restores the existing title).

Unit always comes from **Good** — never stored on positions. Desk rows, trip form
and print all render `good.unit` via the `good_unit` virtual; never hardcode "Mt".
Qty columns are `planned` / `actual` (renamed from `planned_mt` / `actual_mt` in
migration `20260725120000`).

## Balances (`Trading.Balances`)

- **Physical stock movement** only counts trips with `status == "completed"`.
- **Soft hold** = sum of undelivered qty on active sales that prefer a supply — **display only**, does not lock remaining.
- **In transit** (draft + planned) uses `coalesce(actual, planned)` so desks show commitment without moving stock.
- Warehouse on-hand groups by **own_warehouse** location × **line** `good_id`.

**Boards must use the batch helpers, not the per-position ones.** Each
`supply_loaded/1`-style function runs its own query, so calling them per row makes
a board O(rows) round-trips. `position_board` / `sales_board` instead use the
`*_by_ids/1` variants, which answer for a whole id set in one `GROUP BY` and return
`%{id => Decimal}` (absent id ⇒ zero):

`supply_loaded_by_ids/1`, `supply_in_transit_by_ids/1`, `sales_delivered_by_ids/1`,
`sales_in_transit_by_ids/1`, `soft_held_by_ids/1`.

Both boards are now a **flat ~8 queries at any row count** (was 5N+4).
Two further traps:

- `supply_remaining/1` and `sales_undelivered/1` internally re-run the loaded /
  delivered query. When you already have that value, pass it: the arity-2
  `supply_remaining(s, loaded)` / `sales_undelivered(s, delivered)`.
- `soft_held_by_ids/1` exists because the arity-1 `soft_held_for_supply/1` loops
  `sales_undelivered/1` per matching sale — an N+1 nested inside the board's N.

`test/full_circle/trading/board_aggregation_test.exs` pins both halves: aggregated
values equal the per-position functions, and query count does not grow with rows.

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

## Line crew (`trip_load_employees` / `trip_drop_employees`)

Multi-employee per load/drop line. Crew UI only renders when
`transport_mode in ["company_own", "agent"]` (`crew_visible?/1`).

Virtuals on TripLoad / TripDrop:

- `crew_add_name` — employee typeahead; cleared once the row is appended
- `crew_locked` — `true` once the user edits **that line's** crew

**Fill-down:** crew from each *locked* line is copied down onto the following
*unlocked* lines (on add-line, crew add, and crew remove). Deleted lines are
skipped. Removing all crew from a line still leaves it locked — that is how a
line opts out of inheriting. Implemented twice: on changesets
(`fill_down_crew_changesets/3`) and on raw params during validate.

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

**Company-scope every position lookup reached through trip line params.** A trip's
`loads`/`drops` carry client-supplied `supply_position_id` / `sales_position_id`.
`authorize/3` only checks the *user vs. company* — it says nothing about whether a
referenced position belongs to that company. Both places that resolve those ids
must filter on `company_id`:

- `line_goods_mismatch?/3` — an out-of-company position then resolves to "not
  found", mismatches the line's `good_id`, and the changeset is rejected
- `maybe_promote_open_supplies_to_collect/2` — the `update_all` must be scoped, or
  saving a trip could flip another company's supply from `open` to `collect`

Both take `company` as an explicit argument for exactly this reason; don't drop it
back to an arity that "looks tidier".

## Gotchas

1. **Warn-only oversell** — remaining can go negative; `trip_warnings/1` is advisory.
2. **Title uniqueness** — SUP/SAL titles unique per company; supply allows manual title on create only (blank → gapless); do not free-edit after create (trip ref never changes).
3. **Loadable open supplies** — open is intentionally loadable and promotes to collect; do not treat open as non-loadable.
4. **Sample data** — `Trading.SampleData` for demo seed; not production.
5. **Order/Load/Delivery removed** from Product — trading replaced that logistics path for grain.
6. **Migrations collapsed** for undeployed trading schema; prefer current schemas over intermediate migration history.
7. **Crew clears itself on transport-mode switch** — switching away from
   `company_own`/`agent` hides the crew inputs, and the existing `cast_assoc` +
   `on_replace: :delete` already deletes the rows on save. No extra clearing code
   is needed; don't "fix" this. (Trip line ids survive edits because Phoenix
   `inputs_for` emits hidden primary-key inputs.)

## Key files

```
lib/full_circle/trading.ex
lib/full_circle/trading/{supply_position,sales_position,trip,trip_load,trip_drop,
  trip_load_employee,trip_drop_employee,location,balances,settlement,sample_data}.ex
lib/full_circle_web/live/trading_desk_live/
lib/full_circle_web/live/trading_settlement_live/
lib/full_circle_web/live/trading_components.ex
lib/full_circle_web/live/trading_{location,trip,sales,history}_live/
lib/full_circle_web/live/pur_invoice_live/trading_attach_component.ex   # attach direction
test/full_circle/trading/
```
