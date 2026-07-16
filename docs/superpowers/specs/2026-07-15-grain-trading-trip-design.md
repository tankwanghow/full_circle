# Grain Trading Desk — Orders, Positions & Trip Design

**Date:** 2026-07-15  
**Status:** Approved for implementation planning (pending user review of this file)  
**App:** FullCircle (`full_circle`)  
**Scope:** Grain trading only (v1). Swine and poultry sales stay on existing FullCircle invoicing until a later phase.

---

## 1. Problem & goals

### Business context

The company runs multiple lines (grain trading, swine, poultry). **v1 builds only the grain trading desk.**

Grain trade combines:

- **Import / vessel positions** — e.g. May 2026 vessel JON DOE 1000 MT maize; Jun 2026 vessel MARY JAIN 3000 MT.
- **Local product** — often back-to-back; e.g. customer orders 35 MT wheat pollard; lift from supplier warehouse, sometimes direct to customer.
- **Own warehouse** — small orders (e.g. ~5 MT) may stock into company warehouse first; large orders (e.g. full lorry ~60 MT, 1–2 drop sites) usually leave stock at **supplier warehouse / port** until lift.

### v1 success criteria (equal priority)

1. **Position board** — remaining MT by supply position / warehouse / product.  
2. **Open commitments** — what was promised to customers (sales positions) and what is still undelivered.  
3. **Movements** — what was loaded and dropped, from which sources, to which locations, with transport and driver accountability.

Also required:

- **Price** on supply and sales commercial documents (not full margin/P&L dashboards in v1).  
- **Logistics** — multi-load, multi-drop, transport mode, agents, drivers.  
- **Driver pay trail** — load salary and drop salary both based on actual quantities.  
- **Transport agent trail** — quantities to check agent bills to the company.  
- **Settlement** — final Invoice / PurInvoice remain in FullCircle finance (office-triggered from trading actuals).

### Non-goals (v1)

- Swine (live pig) and poultry (eggs, retired layer, dung) order/trip modules.  
- Driver / field mobile app.  
- Hard blocks on oversell or over-allocate (warn only).  
- Full payroll engine, payslips, or automatic agent AP posting (qty registers first).  
- Deal-level margin / P&L dashboards.  
- Silent auto-create of Invoice / PurInvoice without office action.  
- Multi-product lines on a single trip (one product per trip; use multiple trips if needed).

---

## 2. Architecture placement

**Approach: FullCircle trading module (Approach 1).**

| Layer | Responsibility |
|-------|----------------|
| **New Trading domain** in FullCircle | Supply positions, sales positions, soft holds, trips (loads/drops), drivers, transport agents, position/open-sales/trip boards, driver/agent registers |
| **Existing FullCircle** | Company, contacts, goods, auth, **Invoice**, **PurInvoice**, GL, payments, statutory |
| **Tugas** | Out of scope for this feature |
| **New monorepo app** | Not for v1; keep module boundaries clean enough that extraction later is possible |

### Module boundary

- Suggested contexts: `FullCircle.Trading` (commercial + masters) and/or nested trip under the same umbrella.  
- **Do not** overload Invoice / PurInvoice as the order or trip document.  
- Trading documents **link** to Invoice / PurInvoice at settlement time.

---

## 3. Domain model

### 3.1 Supply (sources)

**One entity. No type enum.** Vessel lots, local POs, and any other supply deal are the same record shape. Optional fields describe the deal for humans; behavior is identical.

| Object | Role |
|--------|------|
| **SupplyPosition** | Supply source: open qty, remaining, price, product, supplier, status |
| **Warehouse** (source/destination) | Own stock derived from warehouse in/out on trips; avoid double-entry lot master in v1 if possible |

#### SupplyPosition

```
SupplyPosition
  company_id
  supplier_id                 # contact
  product_id                  # good
  quantity                    # contracted / ordered MT
  unit                        # typically MT (from product)
  unit_price
  status: open | closed
  # optional identity / description (any combination; all optional):
  title?                      # free label for lists, e.g. "JON DOE May maize" or "Ah Huat pollard PO"
  reference_no?               # human-entered ref (PO #, contract #, supplier ref) — not auto-generated
  vessel_name?                # e.g. JON DOE when import
  period? / eta?              # e.g. May 2026
  notes?
```

**Functions (every row):** position board; soft-hold target on SalesPosition; load/drop **source** on Trip; remaining math; optional PurInvoice link.

**How staff tell deals apart:** `title`, `reference_no`, vessel_name, supplier, product — not a system `type`.  
Examples:

- Import: fill `vessel_name` + `period` (+ title / reference_no if useful).  
- Local PO: fill `reference_no` with the PO number.  
- Filters: search on title/reference_no/vessel; open only — no required type filter.

### 3.2 Demand (commitments)

**One entity. No type enum.** Long customer deals and day-to-day orders are the same record shape. Optional `parent_id` links a call-off under a larger deal.

| Object | Role |
|--------|------|
| **SalesPosition** | Customer commitment: promised qty, delivered, undelivered, price, preferred supply, status |

#### SalesPosition

```
SalesPosition
  company_id
  parent_id?                  # optional: this line is under a larger SalesPosition
  customer_id                 # contact
  product_id                  # good
  quantity                    # promised MT
  unit
  unit_price
  preferred_supply_id?        # soft hold → SupplyPosition
  status: draft | open | fulfilled | cancelled
  # optional identity / description:
  title?                      # free label, e.g. "Annual maize 2026" or "Spot 35MT pollard"
  reference_no?               # human-entered ref (customer PO #, our paper ref) — not auto-generated
  period?                     # e.g. covering June
  notes?
  fulfilled_note?             # when manually fulfilled short/over
```

**Functions (every row):**

- Appear on **Open sales**.  
- Soft-hold preferred `SupplyPosition`.  
- **Drop destination** on Trip.  
- Delivered / undelivered from completed drop actuals.  
- **Manual fulfill** case-by-case (e.g. 33.5 of 35).  
- Link to **Invoice** at settlement.

**Parent / call-off (optional link only):**

- Standalone deal: no `parent_id`.  
- Call-off under a larger deal: `parent_id` → another SalesPosition.  
- Parent and child are the same entity; both can receive drops.  
- Rollup display (sum of children) is optional UI; operational truth is each row’s own qty and drop actuals.

### 3.3 Movement (trip)

**One Trip = one loading + delivery process** (one lorry job). It may:

- **Load from multiple locations** (multiple load lines).  
- **Drop to multiple locations** (multiple drop lines: customers and/or own warehouse).

```
Trip
  company_id
  date
  product (one product per trip in v1)
  transport_mode: company_own | agent | customer_arranged
  transport_agent_id?   # when mode = agent
  status: draft | planned | completed | cancelled
  notes?
  # optional:
  reference_no?         # human-entered trip / DO / ticket ref

  loads[]   # 1..n
    source (SupplyPosition | warehouse)
    load_location (text / site label)
    planned_mt
    actual_mt?
    driver_id?          # load driver (own transport)

  drops[]   # 1..n
    destination: sales_position_id? | warehouse
    drop_location (text / site label)
    source (SupplyPosition | warehouse this drop draws from)
    planned_mt
    actual_mt?
    driver_id?          # drop driver (own transport)
    variance_note?
    invoice_id?         # settlement link when created
```

**Transport modes**

| Mode | Agent | Drivers | Money trail |
|------|--------|---------|-------------|
| `company_own` | No | Load driver + drop driver (per line) | Load salary + drop salary from actual MT |
| `agent` | Yes | Optional external driver name as note only | Agent bills company — register by agent + actual MT |
| `customer_arranged` | No | Usually empty | No own driver pay / no agent bill |

**Driver pay**

- Drivers are paid on **loading quantity** and **dropping quantity** separately (**load salary** and **drop salary**).  
- Load driver and drop driver may differ on the same job.  
- Different drop lines may have different drop drivers.  
- v1 records **who + actual MT**; rate tables / payroll posting are optional later.

**Transport agent**

- Track deliveries under each agent so their invoice to the company can be checked.  
- Default register quantity: **drop actual MT** (load actuals also stored and visible).

### 3.4 Settlement (existing finance)

| Situation | Document |
|-----------|----------|
| Delivered to customer | **Invoice** (prefill from drop actuals + SalesPosition price) |
| Purchase recognized / goods into commercial purchase | **PurInvoice** (prefill from supply + actuals) |

Trading remains source of truth for **position and logistics**.  
Invoice / PurInvoice remain source of truth for **AR/AP and GL**.

### 3.5 Masters

- **Driver** — company drivers (name, contact, active).  
- **TransportAgent** — hauliers who bill the company.  
- Customers / suppliers / products — existing FullCircle contacts and goods.

---

## 4. Day-to-day flows

### Flow A — Import vessel position

1. Create **SupplyPosition** (vessel name, period, product, MT, price, supplier; title optional).  
2. Position board shows open MT.  
3. Create **SalesPosition**(s) (optional parent for call-offs) with preferred source = that SupplyPosition (soft hold).  
4. Create **Trip**: one or more loads from port/godowns; one or more drops to customer sites and/or warehouse; transport mode + agent/drivers as applicable.  
5. Enter **actual** MT on loads and drops; variance notes when planned vs actual diverges materially.  
6. Balances update from **completed** actuals.  
7. SalesPosition may remain open even if short (e.g. 33.5 of 35); office **marks fulfilled** case-by-case.  
8. Office **Create Invoice** from delivered actuals when billing.  
9. **PurInvoice** when purchase is recognized (timing is commercial; not forced to a single automatic event).

### Flow B — Local back-to-back (supplier → customer)

1. Create **SupplyPosition** (supplier, product, MT, price, reference_no = PO #).  
2. **SalesPosition** with soft-hold preferred that SupplyPosition.  
3. **Trip** from supplier warehouse to customer drop location(s); mode may be company_own, agent, or customer_arranged.  
4. Actuals → balances; fulfill SalesPosition case-by-case; Invoice / PurInvoice as appropriate.  
5. No mandatory stop at own warehouse.

### Flow C — Small order via own warehouse

1. Trip **in**: load from SupplyPosition → drop warehouse.  
2. Later trip **out**: load warehouse → drop customer site(s).  
3. Same multi-load/multi-drop and driver/agent rules.

### Flow D — Multi-load, multi-drop job

1. One Trip.  
2. Multiple load lines (different locations/sources).  
3. Multiple drop lines (different customers/sites and/or warehouse); each drop names its **source**.  
4. One transport mode (and agent if applicable) for the job; drivers per load/drop line.

---

## 5. Quantity & status rules

### Balance formulas

```
supply_remaining = supply_qty − Σ load.actual_mt
                   (completed trips only, that source)

sales_delivered  = Σ drop.actual_mt (completed, that SalesPosition)
sales_undelivered = sales_qty − sales_delivered
                   (may remain > 0 even when status = fulfilled)

warehouse_qty    = inflows − outflows via warehouse loads/drops

soft_held        = Σ sales_undelivered where preferred_supply = this SupplyPosition
                   (display only; does not lock)

driver_load_mt   = Σ load.actual_mt where load.driver = D
driver_drop_mt   = Σ drop.actual_mt where drop.driver = D

agent_mt         = Σ drop.actual_mt (default) for trips with agent = A
                   (load actuals available for dispute/weighbridge view)
```

### Rules

| Rule | Behavior |
|------|----------|
| What consumes position | **Completed** trip **load actuals** only |
| What reduces sales undelivered | **Completed** trip **drop actuals** only |
| Draft / planned | Do not reduce remaining; optional “planned” columns in UI |
| Oversell / over-allocate / negative remaining | **Warn, allow save** |
| Planned vs actual large gap | Require **note** on the line |
| Σ load actual vs Σ drop actual on one trip | **Warn** if mismatch |
| Soft hold | Preferred SupplyPosition only; never hard reserve |
| Sales fulfillment | **Manual / case-by-case** (e.g. accept 33.5 MT of 35 MT) |
| One product per trip | v1 constraint |
| Each drop names a source | Required so multi-load positions stay correct |

### Statuses

| Object | Statuses |
|--------|----------|
| SupplyPosition | `open` → `closed` |
| SalesPosition | `draft` → `open` → `fulfilled` / `cancelled` |
| Trip | `draft` → `planned` → `completed` / `cancelled` |

### Cancel / edge cases

| Case | Behavior |
|------|----------|
| Cancel completed trip | Block if already invoiced; otherwise reverse balance impact |
| Change preferred source after partial delivery | Allowed; historical actuals stay on sources used |
| Mark SalesPosition fulfilled with undelivered &gt; 0 | Allowed; note recommended |
| Missing load/drop driver on `company_own` complete | Warn (stronger for drop) |
| Missing agent on `agent` complete | Warn |
| FC invoice voided | Trading link shows unlinked / warn; no heavy sync engine in v1 |

---

## 6. UI (desktop, office staff)

### Navigation

```
Trading
├── Position board
├── Open sales
├── Trips
├── Supply positions
├── Sales positions
├── Transport agents
├── Drivers
├── Driver load register
├── Driver drop register
└── Agent delivery register
(+ existing Invoice / PurInvoice)
```

### Screens (summary)

1. **Position board** — remaining by source; soft-held column; price; open/closed; title / reference_no / vessel for identity; drill to detail.  
2. **Open sales** — SalesPositions; ordered / delivered / undelivered; soft hold; mark fulfilled; warnings; filter/search on title/reference_no; optional parent grouping.  
3. **Trip board + form** — multi-load, multi-drop, transport mode, agent, load/drop drivers, planned/actual, warnings.  
4. **Supply / sales forms** — one SupplyPosition form, one SalesPosition form (optional parent on sales; optional **reference_no** human-entered on both).  
5. **Driver load register** — load salary quantity by driver + date.  
6. **Driver drop register** — drop salary quantity by driver + date.  
7. **Agent delivery register** — quantities to check agent invoices.  
8. **Settlement actions** — Create Invoice / PurInvoice prefilled from actuals; store links.

Users: **office sales/ops on desktop** only in v1.

---

## 7. FullCircle integration

- **Company-scoped** like the rest of FullCircle.  
- Reuse contacts (customer/supplier) and goods (product + unit).  
- Authorization: view/manage trading aligned with existing sales/purchase-style permissions; creating Invoice/PurInvoice uses existing invoice permissions.  
- Settlement is **office-triggered**, prefilled from trading actuals and commercial prices.  
- No replacement of existing egg/layer/swine operational modules in v1.

---

## 8. Implementation phases

| Phase | Deliverable |
|-------|-------------|
| **0** | Module skeleton, nav, auth hooks, Driver + TransportAgent masters |
| **1** | SupplyPosition + **Position board** |
| **2** | SalesPosition (optional parent) + soft hold + **Open sales** + manual fulfill |
| **3** | Trip multi-load/multi-drop + actuals + balance updates + **Trip board** |
| **4** | Driver load/drop registers + agent delivery register |
| **5** | Create Invoice / PurInvoice from actuals + links |
| **6** | Polish (DO print, attachments, variance threshold config, optional rates) |

**First demo milestone:** Phases 0–3 (live supply position + open sales position + trip).  
**Phases 4–5** follow so driver/agent money trails and finance settlement catch up.

```
0 → 1 → 2 → 3 → 4
              ↘ 5 → 6
```

Phases 1 and 2 may overlap once supply sources exist for soft-hold references.

---

## 9. Testing focus

- Multi-load / multi-drop balance math (supply remaining, sales undelivered, warehouse).  
- Load driver ≠ drop driver → both registers correct.  
- Agent register totals.  
- Manual fulfill with short delivery (35 ordered, 33.5 delivered).  
- Soft hold does not lock or reduce remaining.  
- Warn-only oversell / load≠drop mismatch.  
- Invoice prefill quantity = drop actuals.  
- Child SalesPosition with parent still receives drops on the child line.  
- Cancel/invoiced guards.

---

## 10. Decisions log

| Decision | Choice |
|----------|--------|
| Business lines in v1 | Grain only; swine/poultry later |
| Stock + linked deals | Both; soft hold preferred source |
| Inventory locations | Supplier/port primary for large; own warehouse for some small |
| Soft hold | Preferred early; firm at actual load/drop; switchable |
| Trip unit | Loading + delivery process; multi-load + multi-drop; formerly called “dispatch” |
| Qty truth | Planned + actual; balances use completed actuals |
| Oversell | Warn only |
| Sales fulfillment | Case-by-case manual, not auto from math |
| Transport | `company_own` / `agent` / `customer_arranged` |
| Drivers | Per load line and per drop line; load salary + drop salary |
| Agent | Per trip; bill check via delivery register |
| Finance home | FullCircle Invoice / PurInvoice; trading links in |
| Host app | FullCircle trading module |
| Clients | Desktop office v1 |
| Supply model | **One entity `SupplyPosition`** — no type enum; optional vessel_name / title / **reference_no** (human-entered) |
| Sales model | **One entity `SalesPosition`** — no type enum; optional `parent_id`; optional **reference_no** (human-entered) |
| Document numbers | No mandatory auto SO/PO number; optional human-entered `reference_no` only (plus system UUID PK) |

---

## 11. Future (explicitly later)

- Swine / poultry trading or farm-sales modules reusing generic source/destination/unit ideas.  
- Mobile capture for drivers.  
- Driver rate tables and payroll integration.  
- Agent PurInvoice generation from register.  
- Margin / P&L by contract.  
- Hard reservation modes if operations ever need them.  
- Multi-product single trip if proven necessary.

---

## 12. Open implementation details (non-blocking)

These do not change the design intent; resolve during planning/implementation:

- Exact Ecto schema / table names (e.g. `supply_positions`, `sales_positions`).  
- Whether TransportAgent/Driver link to `Contact` or standalone tables.  
- Variance threshold default (e.g. % or absolute MT).  
- Exact FullCircle role matrix mapping for new actions.  
- Whether warehouse is a synthetic SupplyPosition-like row or only a destination type with computed stock.  
- Parent rollup display (sum of children vs deliveries on parent only).

---

*End of design. Next step after user approval of this file: implementation plan (`writing-plans`), then build phase-by-phase.*
