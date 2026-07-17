# Desk trip assembly — select sales + sources → prefilled trip

**Date:** 2026-07-17  
**Status:** Approved for planning  
**App:** FullCircle (`full_circle`)  
**Depends on:** Trading Desk UI (`2026-07-16-trading-desk-ui-design.md`), trip domain (`2026-07-15-grain-trading-trip-design.md`)  
**Route:** `/companies/:company_id/trading/desk`

---

## 1. Problem & goals

### Problem

Operators can see open sales, supply, and warehouse stock on the desk, but assembling a trip still means opening **New Trip** and re-typing good, loads, and drops. That breaks the “see commitment → pick stock → move it” loop.

### Goals

1. **Select rows on the desk** (open sales, supply, warehouse) with checkboxes.  
2. **Either side first** — start from sales or from a source; first selection locks **good**.  
3. **Multi sales + multi sources** on one assembly.  
4. **Auto-filter** other panels to the locked good; hide or disable zero on-hand warehouse rows.  
5. **Create Trip** opens the **existing trip modal** prefilled with loads/drops (no new trip form).  
6. Reuse `Trading.create_trip/3` and current trip validation/warnings.

### Non-goals (v1)

- Drag-and-drop assembly.  
- Multi-good trips.  
- Auto-complete trip.  
- Hard block on oversell (warn-only as today).  
- Prefill transport agent / employees.  
- Pure stock-in assembly from warehouse checkboxes only (use normal **New Trip**).  
- Changing remaining / soft-hold / warehouse balance formulas.

---

## 2. Chosen approach

**Approach A — Checkboxes + good lock + Create Trip.**

- Checkbox column on supply, warehouse, and open sales rows.  
- First checked row sets `selected_good_id` (good lock).  
- Subsequent checks must match that good.  
- Selection tray shows summary + **Create Trip** / **Clear**.  
- Create Trip opens desk trip modal with prefilled attrs.

Rejected for v1:

- **Selection mode toolbar only** — extra click; can add later if accidental checks become noisy.  
- **Drag-and-drop** — costly, weak for multi-select and MT editing.

---

## 3. Selection model

### 3.1 State (LiveView assigns)

```elixir
%{
  selected_good_id: nil | binary_id,
  selected_supply_ids: MapSet.t(),
  selected_warehouse_ids: MapSet.t(),  # location ids of own_warehouse rows
  # warehouse rows are location × good; store {location_id, good_id} or row key
  selected_warehouse_keys: MapSet.t(), # e.g. "#{location_id}:#{good_id}"
  selected_sales_ids: MapSet.t()
}
```

Warehouse board is **per location × good**; selection key must include **good** so two goods at the same silo stay independent.

### 3.2 Rules

| Event | Behaviour |
|-------|-----------|
| Check first row (any panel) | Add id to set; set `selected_good_id` from that row’s good. |
| Check further row | Allow only if row’s good == `selected_good_id`; else flash and ignore. |
| Uncheck | Remove id; if all sets empty, clear `selected_good_id`. |
| Clear selection | Empty all sets; clear good lock. |
| Good lock active | Supply / sales / warehouse **display lists** filter to that good (in addition to text filters). Warehouse rows with on-hand ≤ 0 not checkable (and preferably hidden). |
| Text filters | Still apply within the locked-good list. |
| Row click (non-checkbox) | Still opens edit modal. Checkbox uses `phx-click` with stop propagation (or separate control) so check ≠ edit. |

### 3.3 Either side

- Start with open sales → sources filter to good.  
- Start with supply or warehouse → sales filter to good.  
- User may check only sources first, then sales, or reverse.

### 3.4 Create Trip enablement

**Create Trip** enabled when:

- `selected_good_id` set, and  
- **≥ 1 load source** (at least one supply **or** one warehouse key), and  
- **≥ 1 sales** position checked.

v1 does **not** enable Create Trip for warehouse/supply-only (stock-in); use **New Trip**.

---

## 4. Selection tray UI

Place a compact bar between the top panels and the trips table (or sticky under toolbar):

- **Good:** name  
- **Counts:** `N sales · M supply · K warehouse`  
- **Optional hint:** sum of sales undelivered vs sum of supply remaining + warehouse on hand (warn styling if demand > source; never block).  
- **[Create Trip]** (primary when enabled)  
- **[Clear selection]**

Toolbar may duplicate **Create Trip from selection** when enabled.

---

## 5. Prefill trip modal

On Create Trip, open existing desk trip LiveComponent with action `:new` and **prefilled params** (not a blank trip):

| Field | Value |
|-------|--------|
| `date` | Today (company timezone if available; else UTC date) |
| `status` | `draft` |
| `transport_mode` | `company_own` (user can change) |
| `good_id` / `good_name` | Locked good |
| `reference_no` | Empty (user fills) |
| `vehicle_number` | Empty |

### 5.1 Loads

One load line per selected **supply**:

- `supply_position_id` = supply id  
- `location_id` = empty if unknown (user picks port/supplier site)  
- `planned_mt` = `actual_mt` = **supply remaining** (via `Balances.supply_remaining/1`)

One load line per selected **warehouse** key:

- `location_id` = warehouse location id  
- `supply_position_id` = nil  
- `planned_mt` = `actual_mt` = **on hand** for that location × good  

### 5.2 Drops

One drop line per selected **sales**:

- `sales_position_id` = sales id  
- `supply_position_id` = that sales’ `preferred_supply_id` if set and still selected / same good; else if exactly one supply is selected, that supply; else nil  
- `location_id` = best-effort: active `customer_site` location linked to customer if one exists; else empty  
- `planned_mt` = `actual_mt` = **sales undelivered** (`Balances.sales_undelivered/1`)

### 5.3 Qty imbalance

Load total may not equal drop total. **Do not block** Create Trip. Existing trip warnings on complete remain. User edits MT in the modal before save.

### 5.4 After save

Same as today: close modal, flash, `load_panels`, **clear selection** (good lock off).

---

## 6. Desk UI changes (layout)

- Add a leading checkbox column on supply, warehouse, open sales headers/rows (fixed narrow width, e.g. `w-6` / `w-8`).  
- Keep sticky header + scrollbar alignment pattern.  
- Checked row subtle highlight (e.g. `bg-amber-50` / panel-tinted).  
- Disabled checkbox when good lock mismatches (if row still visible) or warehouse on hand ≤ 0.

---

## 7. Domain / API

**No new tables.** Optional helpers (pure functions) in `FullCircle.Trading` or desk module:

- `build_trip_attrs_from_selection(selection, company, user) -> map`  
  Resolves goods, balances, preferred locations; returns attrs map for `create_trip` / form changeset.

Authorization unchanged (`manage_trading` to create trip).

---

## 8. Edge cases

| Case | Handling |
|------|----------|
| Text filter empty after good lock | Show empty panel message |
| Sales draft/hold/open all selectable | Yes (all active open-sales board statuses) |
| Supply closed | Not on board; not selectable |
| Warehouse zero on hand | Not checkable; hide when good locked |
| Soft-held > remaining | Still allow check; warn only on tray / existing complete warnings |
| Edit modal while selection active | Allowed; selection preserved until Clear / successful Create Trip |
| Two goods at same warehouse | Separate row keys; only matching good checkable under lock |

---

## 9. Testing

- LiveView: check sales → supply list filters to good; wrong good cannot check.  
- Multi select: two sales + one warehouse → Create Trip form contains 2 drops + 1 load.  
- Clear resets lock and restores unfiltered lists (subject to text filters).  
- Create Trip disabled until ≥1 source and ≥1 sales.  
- Checkbox does not open edit modal.  
- After save, selection cleared and new trip appears on trips panel.

---

## 10. Implementation sketch (not a full plan)

1. Selection assigns + toggle/clear events on desk LiveView.  
2. Apply good lock in `apply_filters` / display pipeline.  
3. Checkbox column UI + tray.  
4. `build_trip_attrs_from_selection/3`.  
5. Wire Create Trip to trip form component with prefilled attrs.  
6. Tests.

---

## 11. Success criteria

- Operator can build a multi-load / multi-drop draft trip from desk checkboxes without re-entering good or line qty from scratch.  
- Good lock prevents mixed-good assemblies.  
- Trip still editable and completable via existing modal/API.
