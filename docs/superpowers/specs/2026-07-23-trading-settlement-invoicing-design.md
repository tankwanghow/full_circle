# Trading Desk Settlement — Customer Invoice, Supplier Bill, Transport Bill

**Date:** 2026-07-23  
**Status:** Phase A–C implemented; Phase D desk badges (Option C + expand lines) and
trips panel Show/Hide/Maximize implemented; void/delete not in product (unlink + party
lock instead); rate matrix still later  
**Parent:** `docs/superpowers/specs/2026-07-15-grain-trading-trip-design.md` (§3.5 Settlement)  
**Skill:** `.claude/skills/grain-trading-desk.md` (update when implemented)  
**App:** FullCircle (`full_circle`)  
**Scope:** Grain trading settlement only. Reuses existing `Invoice` / `PurInvoice` finance docs.

---

## 1. Problem & goals

### Business need

After logistics are finished, the office must:

1. **Invoice the customer** for delivered grain (verified drops).  
2. **Match supplier bills** to commercial loads (what was actually lifted).  
3. **Match transport-agent bills** to haul work (origin → destination + MT).

Today, trips record loads/drops and complete with `actual_mt`, and `trip_drops.invoice_id` exists but is unused. There is no supplier or transport settlement link, and no desk queues for matching.

### Success criteria

- Office can settle all three streams from **completed** trips only.  
- Matching is explicit (select lines → prefill finance doc → save → write links).  
- No silent auto-create of Invoice / PurInvoice on trip complete.  
- Trading remains source of truth for positions and logistics; finance remains source of truth for AR/AP/GL.

### Confirmed design choice

**“Verified” = trip `status == "completed"`.**  
There is no per-drop verify flag. Completing the trip (which already requires `actual_mt` on every load and drop) is the single gate.

---

## 2. Mental model

| Document | Party | Matched against | Qty / money basis |
|----------|--------|-----------------|-------------------|
| **Customer Invoice** | Customer (SalesPosition) | Drop line(s) | Drop `actual_mt` × sales `unit_price` (editable on invoice) |
| **Supplier PurInvoice** | Supplier (SupplyPosition) | Load line(s) | Load `actual_mt` × supply `unit_price` (editable) |
| **Transport PurInvoice** | Transport agent (`contacts`) | Haul line ≈ drop + origin | From→to locations + MT; RM entered from agent bill |

The three streams are **independent**. Completing a trip unlocks all three; none must wait on the others (commercial SOP may order them in practice; the system does not force order).

---

## 3. Eligibility gates

### Shared

- Trip must be `completed`.  
- Draft / planned / cancelled trips never appear in settlement queues.  
- A line already linked to a settlement document is settled for that stream (not selectable again).

### Per stream

| Stream | Line eligible when |
|--------|--------------------|
| Customer invoice | Drop has `sales_position_id`, `actual_mt` present, `invoice_id` nil |
| Supplier bill | Load has `supply_position_id`, `actual_mt` present, `pur_invoice_id` nil |
| Transport bill | Trip `transport_mode == "agent"`, agent set, haul line not yet linked to a transport pur-invoice |

### Explicitly excluded

| Case | Why |
|------|-----|
| Warehouse **in** drop (no sales) | Stock movement only — not customer AR |
| Warehouse **out** load (no supply) | Not a supplier purchase |
| `company_own` / `customer_arranged` trips | No transport agent bill |
| Lines with nil `actual_mt` | Cannot complete trip without them; defensive filter only |

---

## 4. Data model

### Existing

- `trading_trip_drops.invoice_id` → `invoices.id` (nullable FK) — customer settlement.

### Add

| Column / table | Purpose |
|----------------|---------|
| `trading_trip_loads.pur_invoice_id` | Link commercial load → supplier PurInvoice |
| Transport haul link | Prefer `trading_trip_drops.transport_pur_invoice_id` → `pur_invoices.id` when one haul line = one drop; if multi-origin ambiguity needs a separate row, use a small join table (see §6.3) |

Do **not** invent parallel AR/AP documents. Settlement always creates/links existing Billing entities.

### Derived trip badges (UI only; not stored statuses)

| Stream | Values |
|--------|--------|
| Customer | `uninvoiced` / `partial` / `invoiced` (among eligible sales drops) |
| Supplier | `unbilled` / `partial` / `billed` (among eligible supply loads) |
| Transport | `n/a` (not agent) \| `unbilled` \| `partial` \| `billed` |

---

## 5. Workflows

### 5.1 End-to-end timeline

```
Positions open
    → Assemble Trip (loads + drops, transport mode)
    → Execute haul → enter actuals
    → COMPLETE TRIP   ← single verify gate
    → ┌ Invoice customer (drops)
      ├ Bill supplier (loads)
      └ Bill transport agent (load↔drop haul lines)
    → AR / AP / GL via existing Invoice & PurInvoice
```

### 5.2 Invoice customer (match drops)

**Actor:** Billing clerk with invoice create permission.  
**Entry:** Settlement queue “Uninvoiced deliveries” or action from completed trip / drop.

```
Filter: completed trips, drop.invoice_id IS NULL, sales_position_id present
Group by: customer (+ optional good, sales position, date range)
User selects one or more drops (same customer for one invoice)
Prefill Invoice:
  party  = sales.customer
  lines  = one per drop (or merge by good/price if clerk chooses)
  qty    = drop.actual_mt
  price  = sales.unit_price (editable)
  refs   = TRP-…, SAL-…, drop location, trip date
User saves Invoice (existing Billing.create_invoice path)
Write invoice_id on each selected drop
```

**Rules**

| Rule | Behavior |
|------|----------|
| Multi-drop → one invoice | Allowed (same customer) |
| Multi-customer one trip | Separate invoices per customer |
| Short delivery | Bill `actual_mt` (not planned) |
| Already linked | Not selectable; one drop → at most one invoice |
| Void invoice | Unlink drops (or clear `invoice_id` + warn); trading trip stays completed |
| Warehouse drops | Never in queue |

### 5.3 Bill by supplier (match loads)

**Actor:** AP clerk with pur-invoice create permission.  
**Entry:** Queue “Unbilled loads” or match when supplier bill arrives.

```
Filter: completed loads, load.pur_invoice_id IS NULL, supply_position_id present
Group by: supplier (+ optional SUP title, good, date range)
User selects loads to match the bill
Prefill PurInvoice:
  party  = supply.supplier
  lines  = one per load (or merge by good/price)
  qty    = load.actual_mt
  price  = supply.unit_price (editable)
  refs   = TRP-…, SUP-…, load location, trip date
User saves PurInvoice
Write pur_invoice_id on each selected load
```

**Rules**

| Rule | Behavior |
|------|----------|
| Partial bill | Subset of loads under same supplier/SUP |
| Over/under vs supply qty | Warn if totals look wrong; allow |
| Bill amount ≠ load total | Clerk adjusts PurInvoice lines; unmatched loads stay open |
| Warehouse-only loads | Not in queue |
| Timing | Not forced to complete day — commercial recognition when bill arrives |

### 5.4 Bill by transport agent (match load + drop)

**Actor:** AP clerk.  
**Entry:** Agent register / “Unbilled transport” queue.  
**Only** trips with `transport_mode == "agent"`.

**Haul line (matching unit)** — prefer one row per drop:

```
{
  agent, trip (TRP), date, vehicle_number,
  from_location,   # origin — see origin rules
  to_location,     # drop location
  supply_position?, sales_position?,
  actual_mt        # drop.actual_mt
}
```

**Origin rules**

| Trip shape | Origin for agent match |
|------------|------------------------|
| 1 load → N drops | That load’s location for every drop |
| N loads → 1 drop | Show all load origins; clerk confirms primary origin if needed |
| N×N | Prefer load whose `supply_position_id` matches `drop.supply_position_id`; else clerk picks origin |

**Workflow**

```
Filter: completed agent trips; haul line not yet linked
Group by: transport_agent (+ date range, from→to route)
User selects lines that appear on agent’s bill
Prefill PurInvoice (party = transport_agent contact):
  description e.g. "TRP-000123 Port A → Customer site B"
  qty / unit as clerk needs (MT or trip count)
  unit_price blank (v1: no mileage matrix) — clerk enters from bill
  refs: TRP, from/to, vehicle_number
Save PurInvoice
Link selected haul lines to that pur_invoice
```

**Rules**

| Rule | Behavior |
|------|----------|
| No auto haulage RM | v1: office matches Locations + MT against agent bill |
| One haul line → one transport bill | Same as other streams |
| Multi-day agent invoice | Select lines across trips/dates in one PurInvoice |
| company_own / customer_arranged | Never in queue |

---

## 6. Implementation notes

### 6.1 Context API (sketch)

Under `FullCircle.Trading` (or `Trading.Settlement`):

- `list_uninvoiced_drops(company, filters)`  
- `list_unbilled_loads(company, filters)`  
- `list_unbilled_transport_lines(company, filters)`  
- `build_invoice_attrs_from_drops(drops, company, user)`  
- `build_pur_invoice_attrs_from_loads(loads, company, user)`  
- `build_pur_invoice_attrs_from_transport_lines(lines, company, user)`  
- `link_drops_to_invoice(drops, invoice, company, user)`  
- `link_loads_to_pur_invoice(loads, pur_invoice, company, user)`  
- `link_transport_lines_to_pur_invoice(lines, pur_invoice, company, user)`  

Prefill helpers produce attrs compatible with existing `Billing.create_invoice` / `create_pur_invoice`. Linking runs in the same Multi after successful create (or after attaching to an existing draft if product allows — v1 can create-only).

### 6.2 Authorization

- Viewing settlement queues: `:view_trading` (or mirror invoice list visibility).  
- Creating Invoice / PurInvoice: existing Billing permissions (`can?` for invoice/pur_invoice create).  
- Linking from trading: require both trading manage (or a dedicated settle right) **and** finance create right — implementers should follow existing Billing LiveView auth patterns.

### 6.3 Transport link storage

**Recommended v1:** `trading_trip_drops.transport_pur_invoice_id` nullable FK to `pur_invoices`.  

Origin for display/match is computed at query time from trip loads (rules in §5.4). Store origin only if clerk must override; optional later column `transport_origin_location_id` on the drop if overrides become common.

Avoid a heavy allocation engine (splitting one agent charge across loads/drops by formula) in v1.

### 6.4 Void / reverse

| Event | Trading behavior |
|-------|------------------|
| Invoice voided / deleted | Clear `trip_drops.invoice_id`; drop reappears in uninvoiced queue |
| Supplier PurInvoice voided | Clear `trip_loads.pur_invoice_id` |
| Transport PurInvoice voided | Clear transport link |
| Trip cancel after settlement | Block cancel if any settlement link exists (aligns with parent design: “Block if already invoiced”) |
| Trip still completed after unlink | Yes — logistics history unchanged |

Exact void hooks depend on how Billing voids documents today; prefer explicit clear-on-void over silent orphans.

### 6.5 UI surfaces

| Surface | Role |
|---------|------|
| Settlement queues (desk or under trading menu) | Uninvoiced drops / unbilled loads / unbilled transport |
| Completed trip detail | Per-line settlement status + “Invoice / Bill” actions |
| Existing Invoice / PurInvoice form | Prefill entry; print/email unchanged |
| Agent register report | Filter by agent, route, billed/unbilled (extends parent § agent trail) |

Desk badges on completed trips: customer / supplier / transport settlement state.

### 6.6 Phased delivery

| Phase | Deliverable |
|-------|-------------|
| **A** | Customer: uninvoiced-drops queue + prefill Invoice + set `trip_drops.invoice_id` |
| **B** | Supplier: `trip_loads.pur_invoice_id` + unbilled-loads queue + prefill PurInvoice |
| **C** | Transport: agent register + match UI + transport pur-invoice link |
| **D** | Desk badges, void/unlink polish, optional rate matrix (later) |

---

## 7. Worked example (back-to-back)

1. **SUP-00010** — Supplier A, corn 100 MT @ 900.  
2. **SAL-00020** — Customer B, corn 30 MT @ 1050.  
3. **TRP-00050** — agent “Haul Co”, vehicle ABC123.  
   - Load: Port (SUP-00010) planned 30 → **actual 29.8**.  
   - Drop: Customer site (SAL-00020) planned 30 → **actual 29.6** + variance note.  
4. **Complete trip.**  
5. **Invoice customer:** 29.6 × 1050 → Invoice to B; link drop.  
6. **Supplier bill:** match load 29.8 × 900 → PurInvoice to A; link load.  
7. **Agent bill:** Port → Customer site, 29.6 MT; clerk enters RM from Haul Co invoice → PurInvoice to agent; link haul line.

**Warehouse path:** load SUP → drop warehouse (no customer invoice; supplier match on load). Later load warehouse → drop customer (customer invoice on second drop only).

---

## 8. Non-goals (v1)

- Per-drop or per-load “verified” flag separate from trip complete.  
- Silent auto-create Invoice / PurInvoice on complete.  
- Mileage rate matrix / auto-calculated haulage RM.  
- Blocking trip complete when lines are uninvoiced/unbilled.  
- Hard system rule “supplier only after customer invoiced” (office SOP only).  
- Deal-level margin/P&L dashboard.  
- Changing Invoice/PurInvoice GL posting rules.  
- Swine/poultry settlement modules.

---

## 9. Testing strategy

- Context: eligibility queries exclude draft/planned and already-linked lines.  
- Prefill attrs: party, qty from actuals, price from positions, multi-line same party.  
- Link Multi: create invoice + set FKs atomic; partial failure leaves no half-links.  
- Completing trip does **not** create finance docs.  
- Cancel completed trip with links → error.  
- Void finance doc → lines reappear in queue (if void path exists).  
- Transport: only agent trips; origin resolution for 1:N and supply-matched N:N.  
- LiveView: queues render, selection groups by party, unauthorized user blocked.

---

## 10. Open items (resolve during implementation plan)

1. Exact Invoice/PurInvoice line schema fields for prefill (description, account, tax code defaults from existing forms).  
2. Whether linking to an **existing** draft invoice is needed in phase A or create-only.  
3. Transport link: column on drop vs join table (default: column on drop).  
4. Menu placement: new “Settlement” tab on desk vs separate LiveViews under trading.  
5. Update `.claude/skills/grain-trading-desk.md` settlement section when shipping.

---

## 11. Approval record

- Verify gate: **trip completed only** (option A) — confirmed 2026-07-23.  
- Design outline approved; this document is the written spec for implementation planning.
