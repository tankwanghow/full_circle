# Trading Desk UI — Unified Screen + Modal Forms

**Date:** 2026-07-16  
**Status:** Draft for review  
**App:** FullCircle (`full_circle`)  
**Depends on:** Grain trading domain already in place (supply, sales, locations, trips, warehouse board)  
**Parent design:** `docs/superpowers/specs/2026-07-15-grain-trading-trip-design.md`

---

## 1. Problem & goals

### Problem

Operators jump between separate LiveViews (position board, warehouse board, open sales, trips, and each form route). Day-to-day work is one loop: **see stock / commitments → plan or complete a trip → watch boards update**. Fragmented navigation slows that loop.

### Goals

1. **One primary screen** — Trading Desk — shows supply, warehouse, sales, and trips together.  
2. **Create / edit** supply, sales, trip (and optionally location) via **modal forms**, without leaving the desk.  
3. **Reuse domain APIs** already on `FullCircle.Trading` — no change to remaining/soft-hold/warehouse math.  
4. **Desktop-first** (same as trading v1).  
5. Default nav entry for Trading becomes the desk; deep list routes may remain for power users.

### Non-goals

- Feed production / internal consumption documents beyond existing trip patterns.  
- Mobile field app.  
- Drag-and-drop kanban between panels.  
- Hard blocks on oversell (still warn-only).  
- Changing Invoice/PurInvoice settlement flow.  
- Replacing domain schemas or trip multi-load rules.

---

## 2. Chosen approach

**Stacked panels + modals (Approach A).**

- Single LiveView route: `/companies/:company_id/trading/desk` (or `/trading` if preferred).  
- Four panels on one page.  
- Toolbar actions open modals.  
- Row click opens edit modal (or large trip modal).  
- After save / complete / cancel, panels **reload** from context.

Rejected for v1:

- **Tabs only** — not unified enough.  
- **Kanban / canvas** — high cost, weak for MT numbers.

---

## 3. Layout

### 3.1 Desktop wireframe

Left column stacks **stock sources** (supply then warehouse). Right column is **demand** (open sales). Trips stay full width under both.

```
┌─ Trading Desk ─────────────────────────────────────────────────────┐
│ [Good ▾]  [Refresh]     [+ Supply] [+ Sales] [+ Trip] [+ Location?] │
├─────────────────────────────┬──────────────────────────────────────┤
│ SUPPLY (active)             │ OPEN SALES (draft/open/hold)         │
│ title · status · remaining  │ title · customer · undelivered       │
│ soft-held · price           │ preferred supply · status            │
│ (click → edit modal)        │ (click → edit modal)                 │
│ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─  │                                      │
│ WAREHOUSE (own_warehouse)   │                                      │
│ name · in · out · on hand   │                                      │
│ (same left column partition)│                                      │
├─────────────────────────────┴──────────────────────────────────────┤
│ TRIPS (recent first; filter draft/planned/completed optional)      │
│ date · ref · good · mode · status · loads/drops counts             │
│ (click → large trip modal)  [Complete] on row optional             │
└────────────────────────────────────────────────────────────────────┘
```

**Column model**

| Column | Partitions (stacked) | Role |
|--------|----------------------|------|
| **Left** | (1) Supply (2) Warehouse | Physical / commercial **sources** |
| **Right** | Open sales | **Demand** / commitments |
| **Bottom** | Trips (full width) | **Movements** |

Warehouse is **not** a full-width band under both columns; it sits under supply in the left column, separated by a clear partition (border / sub-heading).

### 3.2 Panel content (data sources)

| Panel | Source | Rows |
|-------|--------|------|
| Supply | `Trading.position_board/2` | Active supplies (open/hold/collect) with remaining, soft_held, loaded |
| Open sales | `Trading.list_open_sales/2` + balances | draft/open/hold; ordered / delivered / undelivered |
| Warehouse | `Trading.warehouse_board/2` | own_warehouse locations; in / out / on hand |
| Trips | `Trading.list_trips/2` | Default: all recent, or last N / open statuses — implementer chooses sensible default (e.g. draft+planned first 50, or all ordered by date desc) |

Use **flex** layouts (not CSS grid) for panel rows, consistent with recent trading UI work.

### 3.3 Toolbar

- **Good filter** (optional v1): filter all panels by `good_id` when set.  
- **+ Supply / + Sales / + Trip**: open create modal.  
- **+ Location**: optional v1 — useful for warehouse; can defer to existing location routes if map modal is heavy.  
- **Refresh**: re-fetch all panels (also after modal close).

### 3.4 Responsive

- Desktop: 2×2 top (supply | sales), full-width warehouse, full-width trips.  
- Narrow: stack all four vertically. No mobile redesign beyond stack.

---

## 4. Modals

### 4.1 Pattern

- Use existing FullCircle modal pattern (`show_modal` / LiveComponent or nested live view).  
- Prefer **LiveComponent** per form so the desk LiveView owns state and can `send_update` / reassign panels after save.  
- Forms call the same `Trading.create_*` / `update_*` / `complete_trip` / `cancel_trip` as today.  
- On success: close modal, flash, **reload panel assigns**.  
- On error: keep modal open, show changeset errors.

### 4.2 Modal inventory

| Action | Content | Size |
|--------|---------|------|
| New / edit supply | Fields from current supply form (title, supplier, good, qty, price, status, available_from, notes) | Medium |
| New / edit sales | Current sales form (customer, good, qty, preferred supply typeahead, status, notes, fulfill actions) | Medium |
| New / edit trip | Current trip form (header + dynamic loads/drops + complete/cancel) | **Large** (~90% width / slide-over) |
| Edit location (optional) | Location form including GPS map picker | Large (map needs height) |

### 4.3 Trip modal specifics

- Must support multi load/drop, autocomplete good/agent, supply options (`loadable_statuses`), sales options.  
- **Complete trip** / **Cancel trip** stay on the modal (same as form LiveView today).  
- Warnings on complete still non-blocking (flash / banner in modal).  
- Opening complete/cancelled trip: read-only or limited edit (same lock rules as `update_trip`).

### 4.4 What stays out of modals (v1)

- Full location **list** with GPS map for every row — link “Locations” or optional location modal.  
- Settlement Invoice create (still later task / existing paths).  
- Employee/agent **registers** (separate reports later).

---

## 5. Routing & navigation

| Route | Role |
|-------|------|
| `GET …/trading/desk` | **Primary** Trading Desk LiveView |
| Existing `…/trading/supply_positions`, `…/sales_positions`, `…/trips`, etc. | Keep for deep links / bookmarks; may slim later |
| Dashboard Trading group | **Desk** first; then boards as secondary links if desired |

Auth: same `view_trading` / `manage_trading` as today. Mount redirects if no view; modal save requires manage.

---

## 6. LiveView architecture

```
TradingDeskLive.Index
  ├── assigns: supplies, sales_rows, warehouse_rows, trips, filters, modal
  ├── handle_event open_modal / close_modal / filter_good / refresh
  ├── on form save: close modal + load_all_panels/1
  └── children (LiveComponents or inline):
        SupplyPanel, SalesPanel, WarehousePanel, TripPanel
        SupplyFormComponent, SalesFormComponent, TripFormComponent
```

**Modal state** (example):

```elixir
%{
  kind: :supply | :sales | :trip | :location | nil,
  action: :new | :edit,
  id: nil | binary_id
}
```

Extract form logic from existing `Trading*Live.Form` modules into components **or** mount those forms inside a modal shell — prefer shared modules to avoid dual maintenance.

**GPS map picker:** only on location modal; hook already `phx-update="ignore"` — keep that boundary.

---

## 7. Data refresh rules

| Event | Refresh |
|-------|---------|
| Modal save supply/sales | Supply + sales panels (+ warehouse only if needed; usually not) |
| Modal save / complete / cancel trip | **All** panels (supply remaining, warehouse, sales delivered, trips) |
| Soft hold on sales | Supply soft_held column |
| Promote open→collect on load save | Supply panel statuses |

Avoid full page navigation after save.

---

## 8. Permissions & empty states

- View-only roles: see desk, no + buttons, no complete, open rows read-only or no edit.  
- Empty panels: short message + CTA if manage (e.g. “No open supply — New Supply”).  
- Warehouse empty: point to Locations with kind own_warehouse.

---

## 9. Implementation phases

### Phase 1 — Desk shell

- Route + LiveView + four read-only panels wired to existing context.  
- Dashboard link to desk.  
- Flex styling consistent with boards.

### Phase 2 — Supply & sales modals

- LiveComponents for create/edit.  
- Toolbar + row click.  
- Refresh panels on save.

### Phase 3 — Trip large modal

- Port trip form into large modal component.  
- Complete/cancel + promote open→collect (already in context).  
- Full panel refresh.

### Phase 4 — Polish

- Good filter across panels.  
- Optional location modal.  
- Deprecate or secondary-nav old index routes.  
- LiveView tests for desk mount + open modal + save refresh.

---

## 10. Testing

- Context: no new domain logic required for Phase 1–2 beyond desk queries if any.  
- LiveView: desk renders panels; unauthorized redirect; modal create supply appears on board after save; complete trip updates warehouse/supply panels (integration-style).  
- Keep existing form tests; component tests as extracted.

---

## 11. Open decisions (defaults if no pushback)

| Topic | Default |
|-------|---------|
| Path | `/trading/desk` |
| Location modal in v1 | **Defer** — link to location routes / warehouse board |
| Trip list filter | All trips, newest first, cap 50 with “View all trips” link |
| Good filter | Phase 4 |
| Old index routes | Keep until Phase 4 |

---

## 12. Success criteria

1. Operator can run a full day from **one URL**: see supply + sales + warehouse + trips.  
2. Create supply, sales, and trip **without leaving** the desk.  
3. Completing a trip updates remaining / warehouse / sales undelivered on the same screen.  
4. No regression to domain rules (auth, warn-only, open→collect on load, GPS on location form if still separate).

---

## 13. Out of this UI design

- Feedmill production consumption document.  
- Settlement from desk (can be a later button).  
- Mobile layout polish.  
- Real-time multi-user board sync (PubSub optional later).
