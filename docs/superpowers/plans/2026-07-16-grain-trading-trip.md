# Grain Trading Desk (Trip) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a grain trading desk inside FullCircle: supply/sales positions, multi-load multi-drop trips, Locations, drivers/agents, balance boards, pay/bill qty registers, and office-triggered Invoice/PurInvoice settlement.

**Architecture:** New `FullCircle.Trading` context (schemas under `lib/full_circle/trading/`) company-scoped like the rest of the app. Trips own loads/drops; balances recompute from **completed** trip actuals only. Soft holds and oversell **warn, never block**. Settlement calls existing `FullCircle.Billing` create paths and stores FK links on drops (and supply when purchasing). Desktop LiveViews only under `/companies/:company_id/trading/...`.

**Tech Stack:** Phoenix LiveView, Ecto/`use FullCircle.Schema` (binary_id), Decimal quantities/prices, existing Contact/Good masters, `FullCircle.Authorization.can?/3`, Gettext.

**Spec:** `docs/superpowers/specs/2026-07-15-grain-trading-trip-design.md`

## Global Constraints

- Grain only; no swine/poultry modules.
- `use FullCircle.Schema` (binary_id PKs/FKs); always scope by `company_id`.
- Context owns logic; LiveViews call `FullCircle.Trading`, never `Repo` directly (tests may use Repo).
- Multi-step writes use `Ecto.Multi`.
- Auth: `can?(user, :view_trading, company)` and `can?(user, :manage_trading, company)` — same role sets as invoice create (`admin manager supervisor clerk cashier`) for manage; view also allows `auditor`.
- Warn-only: negative remaining, load≠drop totals, missing driver/agent on complete, soft-hold oversell.
- One product per trip (v1).
- No auto Invoice/PurInvoice; office clicks create.
- No type enums on SupplyPosition/SalesPosition; optional `reference_no` (human-entered).
- Physical places = **Location** master; Contact mail address is finance-only.
- Before LiveViews: copy patterns from `lib/full_circle_web/live/tax_code_live/` or `salary_type_live/` (index + form + index_component, gettext, light/dark classes).
- All user-facing strings in `gettext`.
- Commit one logical task at a time on `master` (solo workflow); do not push unless asked.
- Run `mix test path/to/test.exs` after each task; full suite / compile warnings before calling a phase done.

## File Structure

| Path | Responsibility |
|------|----------------|
| `lib/full_circle/trading.ex` | Public context API |
| `lib/full_circle/trading/location.ex` | Location schema (only new master table) |
| Drivers | Existing `FullCircle.HR.Employee` — no trading_drivers table |
| Transport agents | Existing `FullCircle.Accounting.Contact` — no trading_transport_agents table |
| `lib/full_circle/trading/supply_position.ex` | Supply position schema |
| `lib/full_circle/trading/sales_position.ex` | Sales position schema |
| `lib/full_circle/trading/trip.ex` | Trip header + embeds/assocs |
| `lib/full_circle/trading/trip_load.ex` | Load line |
| `lib/full_circle/trading/trip_drop.ex` | Drop line |
| `lib/full_circle/trading/balances.ex` | Pure remaining/delivered/warehouse math helpers |
| `priv/repo/migrations/*_create_trading_*.exs` | Tables |
| `lib/full_circle/authorization.ex` | `:view_trading`, `:manage_trading` |
| `lib/full_circle_web/router.ex` | Trading routes |
| `lib/full_circle_web/live/trading_*_live/*` | LiveViews (masters, boards, trip form, registers) |
| `lib/full_circle_web/components/layouts/root.html.heex` (or company nav source) | Trading nav links |
| `test/full_circle/trading/*_test.exs` | Context/balance tests |
| `test/full_circle_web/live/trading_*_test.exs` | LiveView tests |
| `test/support/fixtures/trading_fixtures.ex` | Test fixtures |

---

### Task 1: Auth + Trading masters schemas (Location, Driver, TransportAgent)

**Files:**
- Create: migration `priv/repo/migrations/YYYYMMDDHHMMSS_create_trading_masters.exs`
- Create: `lib/full_circle/trading/location.ex`, `driver.ex`, `transport_agent.ex`
- Create: `lib/full_circle/trading.ex` (stub CRUD for masters)
- Modify: `lib/full_circle/authorization.ex`
- Create: `test/full_circle/trading/masters_test.exs`
- Create: `test/support/fixtures/trading_fixtures.ex`

**Interfaces (produce):**
- `FullCircle.Trading.create_location(attrs, company, user) :: {:ok, Location} | {:error, changeset} | :not_authorise`
- Same pattern: `update_location/4`, `list_locations/2`, `get_location!/3`
- Parallel for `Driver`, `TransportAgent`
- Location `kind` ∈ `~w(port supplier_site customer_site own_warehouse other)`
- Auth: `can?(user, :manage_trading, company)` for write; `can?(user, :view_trading, company)` for list/get

**Schema fields:**

```elixir
# Location
field :name, :string
field :kind, :string
field :address_note, :string
field :active, :boolean, default: true
belongs_to :company, FullCircle.Sys.Company
belongs_to :contact, FullCircle.Accounting.Contact  # optional

# Driver / TransportAgent
field :name, :string
field :phone, :string
field :active, :boolean, default: true
belongs_to :company, FullCircle.Sys.Company
belongs_to :contact, FullCircle.Accounting.Contact  # optional
```

- [ ] **Step 1: Add authorization clauses**

```elixir
def can?(user, :view_trading, company),
  do: allow_roles(~w(admin manager supervisor clerk cashier auditor), company, user)

def can?(user, :manage_trading, company),
  do: allow_roles(~w(admin manager supervisor clerk cashier), company, user)
```

- [ ] **Step 2: Write failing test** `test/full_circle/trading/masters_test.exs`

Use existing company/user fixtures from the app (see `test/full_circle/product_test.exs` or `accounting_test.exs` for how `company` + `user` are built). Assert:
- admin can create location `kind: "own_warehouse"`, name required
- invalid kind rejected
- clerk without role denied if you can construct a guest — at minimum `manage_trading` false for role `"guest"` via `can?/3`
- list_locations only returns same company

- [ ] **Step 3: Run test — expect FAIL** (module missing)

```bash
cd full_circle && mix test test/full_circle/trading/masters_test.exs
```

- [ ] **Step 4: Migration + schemas + Trading context CRUD**

Migration creates `trading_locations`, `trading_drivers`, `trading_transport_agents` with `company_id` references, binary_id PKs, timestamps.

Context pattern:

```elixir
def create_location(attrs, com, user) do
  case FullCircle.Authorization.can?(user, :manage_trading, com) do
    true ->
      %Location{}
      |> Location.changeset(Map.put(attrs, "company_id", com.id))
      |> Repo.insert()
    false -> :not_authorise
  end
end
```

(Use string or atom keys consistently with the rest of FullCircle — prefer matching nearby contexts.)

- [ ] **Step 5: Tests green**

```bash
mix test test/full_circle/trading/masters_test.exs
```

- [ ] **Step 6: Commit**

```bash
git add priv/repo/migrations lib/full_circle/trading lib/full_circle/trading.ex lib/full_circle/authorization.ex test/full_circle/trading test/support/fixtures/trading_fixtures.ex
git commit -m "feat(trading): masters Location, Driver, TransportAgent + auth"
```

---

### Task 2: Master LiveViews + nav + routes

**Files:**
- Create: `lib/full_circle_web/live/trading_location_live/{index.ex,form.ex,index_component.ex}`
- Create: `lib/full_circle_web/live/trading_driver_live/{index.ex,form.ex,index_component.ex}`
- Create: `lib/full_circle_web/live/trading_transport_agent_live/{index.ex,form.ex,index_component.ex}`
- Modify: `lib/full_circle_web/router.ex` (inside `scope "/companies/:company_id"` authenticated live_session)
- Modify: company navigation (find where Invoice/Contact links are rendered — often dashboard or a shared menu component; add a **Trading** group)
- Test: `test/full_circle_web/live/trading_location_live_test.exs` (one solid master is enough; drivers/agents can share pattern)

**Routes:**

```elixir
live "/trading/locations", TradingLocationLive.Index, :index
live "/trading/locations/new", TradingLocationLive.Form, :new
live "/trading/locations/:id/edit", TradingLocationLive.Form, :edit

live "/trading/drivers", TradingDriverLive.Index, :index
live "/trading/drivers/new", TradingDriverLive.Form, :new
live "/trading/drivers/:id/edit", TradingDriverLive.Form, :edit

live "/trading/transport_agents", TradingTransportAgentLive.Index, :index
live "/trading/transport_agents/new", TradingTransportAgentLive.Form, :new
live "/trading/transport_agents/:id/edit", TradingTransportAgentLive.Form, :edit
```

**Behavior:** CRUD list/search/active filter; mount redirects if `!can?(:view_trading)`; form save requires `:manage_trading`. Location form: name, kind select, optional contact autocomplete (copy contact autocomplete from invoice form), address_note, active.

- [ ] **Step 1: Failing LiveView test** — admin visits locations index, creates location, sees it listed; unauthorized role redirected.
- [ ] **Step 2: Implement LVs + routes + nav**
- [ ] **Step 3: `mix test test/full_circle_web/live/trading_location_live_test.exs` green**
- [ ] **Step 4: Commit** `feat(trading): LiveViews for locations, drivers, transport agents`

---

### Task 3: SupplyPosition + position board (context)

**Files:**
- Create: migration `*_create_trading_supply_positions.exs`
- Create: `lib/full_circle/trading/supply_position.ex`
- Create: `lib/full_circle/trading/balances.ex`
- Modify: `lib/full_circle/trading.ex`
- Create: `test/full_circle/trading/supply_position_test.exs`
- Extend: `trading_fixtures.ex`

**Schema:**

```elixir
schema "trading_supply_positions" do
  field :title, :string
  field :reference_no, :string
  field :vessel_name, :string
  field :period, :string
  field :quantity, :decimal
  field :unit, :string
  field :unit_price, :decimal
  field :status, :string, default: "open"  # open | closed
  field :notes, :string
  belongs_to :company, FullCircle.Sys.Company
  belongs_to :supplier, FullCircle.Accounting.Contact
  belongs_to :good, FullCircle.Product.Good  # verify module name in codebase (Good vs Goods)
  timestamps(type: :utc_datetime)
end
```

**Balances (v1 without trips yet):**

```elixir
# FullCircle.Trading.Balances
def supply_loaded(%SupplyPosition{id: id}) do
  # query sum trip_loads.actual_mt where trip.status == "completed" and supply_position_id == id
  # return Decimal; 0 if no trips table yet — implement fully in Task 6, for now return Decimal.new(0)
end

def supply_remaining(%SupplyPosition{} = s) do
  Decimal.sub(s.quantity || 0, supply_loaded(s))
end
```

**Context API:**
- `create_supply_position/3`, `update_supply_position/4`, `close_supply_position/3`, `list_supply_positions/3` (filters: status, search)
- `position_board/2` → list of maps `%{supply, remaining, soft_held, loaded}` — `soft_held` 0 until sales exist (Task 4)

- [ ] **Step 1: Failing tests** — create open supply 100 MT maize; remaining == 100; close sets status closed; validate quantity > 0, supplier+good required
- [ ] **Step 2: Implement migration, schema, context, balances stub**
- [ ] **Step 3: Tests green + commit** `feat(trading): SupplyPosition and position board data`

**Note:** Confirm `FullCircle.Product.Good` module path by grepping `defmodule FullCircle.*Good`.

---

### Task 4: Supply LiveViews (list + form + position board)

**Files:**
- Create: `lib/full_circle_web/live/trading_supply_live/{index.ex,form.ex,index_component.ex}`
- Create: `lib/full_circle_web/live/trading_position_board_live/index.ex`
- Modify: router + nav
- Test: `test/full_circle_web/live/trading_position_board_live_test.exs`

**Routes:**

```elixir
live "/trading/position_board", TradingPositionBoardLive.Index, :index
live "/trading/supply_positions", TradingSupplyLive.Index, :index
live "/trading/supply_positions/new", TradingSupplyLive.Form, :new
live "/trading/supply_positions/:id/edit", TradingSupplyLive.Form, :edit
```

**UI columns (position board):** title/reference/vessel, supplier, good, quantity, loaded, remaining (warn style if negative), soft_held, unit_price, status.

- [ ] Failing test: create supply via fixture, board shows remaining.  
- [ ] Implement.  
- [ ] Green + commit `feat(trading): supply forms and position board UI`

---

### Task 5: SalesPosition + soft hold + manual fulfill

**Files:**
- Create: migration `*_create_trading_sales_positions.exs`
- Create: `lib/full_circle/trading/sales_position.ex`
- Modify: `trading.ex`, `balances.ex`
- Create: `test/full_circle/trading/sales_position_test.exs`
- LiveViews: `trading_sales_live/{index,form,index_component}`, `trading_open_sales_live/index.ex`
- Router + nav + tests

**Schema:**

```elixir
schema "trading_sales_positions" do
  field :title, :string
  field :reference_no, :string
  field :period, :string
  field :quantity, :decimal
  field :unit, :string
  field :unit_price, :decimal
  field :status, :string, default: "draft" # draft | open | fulfilled | cancelled
  field :notes, :string
  field :fulfilled_note, :string
  belongs_to :company, FullCircle.Sys.Company
  belongs_to :customer, FullCircle.Accounting.Contact
  belongs_to :good, FullCircle.Product.Good
  belongs_to :parent, __MODULE__
  belongs_to :preferred_supply, FullCircle.Trading.SupplyPosition
  timestamps(type: :utc_datetime)
end
```

**Balances:**

```elixir
def sales_delivered(%SalesPosition{id: id}) do
  # sum completed trip_drops.actual_mt for sales_position_id — 0 until Task 6
end

def sales_undelivered(%SalesPosition{} = s) do
  Decimal.sub(s.quantity || 0, sales_delivered(s))
end

def soft_held_for_supply(supply_id) do
  # sum undelivered for open/draft sales with preferred_supply_id == supply_id and status not cancelled/fulfilled
  # undelivered for fulfilled still computed but soft_held should only count status in open/draft
end
```

**API:**
- `create_sales_position/3`, `update_sales_position/4`
- `open_sales_position/3`, `fulfil_sales_position/4` (attrs may include `fulfilled_note`; **allowed even if undelivered > 0**)
- `cancel_sales_position/4`
- `list_open_sales/2`

**Tests:**
- Soft hold does not change supply remaining
- Fulfill with undelivered 1.5 after setting delivered stub OR after Task 6 integration
- Parent call-off: child with `parent_id` validates same company

**LiveViews / routes:**

```elixir
live "/trading/open_sales", TradingOpenSalesLive.Index, :index
live "/trading/sales_positions", TradingSalesLive.Index, :index
live "/trading/sales_positions/new", TradingSalesLive.Form, :new
live "/trading/sales_positions/:id/edit", TradingSalesLive.Form, :edit
```

Open sales: ordered / delivered / undelivered / preferred supply / Mark fulfilled button.

- [ ] Implement TDD for context, then LiveViews.  
- [ ] Commit `feat(trading): SalesPosition, soft hold, open sales, manual fulfill`

---

### Task 6: Trip + loads + drops + live balances

**Files:**
- Create: migration(s) for `trading_trips`, `trading_trip_loads`, `trading_trip_drops`
- Create: `trip.ex`, `trip_load.ex`, `trip_drop.ex`
- Modify: `trading.ex`, `balances.ex` (replace stubs with real queries)
- Create: `test/full_circle/trading/trip_test.exs`, `balances_test.exs`
- LiveViews: `trading_trip_live/{index,form,index_component}`
- Router + nav + LV tests

**Schemas (summary):**

```elixir
# Trip
field :date, :date
field :transport_mode, :string  # company_own | agent | customer_arranged
field :status, :string, default: "draft" # draft | planned | completed | cancelled
field :notes, :string
field :reference_no, :string
belongs_to :company, ...
belongs_to :good, ...
belongs_to :transport_agent, FullCircle.Trading.TransportAgent
has_many :loads, TripLoad, on_replace: :delete
has_many :drops, TripDrop, on_replace: :delete

# TripLoad
field :planned_mt, :decimal
field :actual_mt, :decimal
field :location_note, :string
belongs_to :trip, Trip
belongs_to :supply_position, SupplyPosition
belongs_to :location, Location  # required
has_many :employees, through: [:trip_load_employees, :employee]  # many workers per load

# TripDrop
field :planned_mt, :decimal
field :actual_mt, :decimal
field :location_note, :string
field :variance_note, :string
belongs_to :trip, Trip
belongs_to :sales_position, SalesPosition
belongs_to :location, Location  # required
belongs_to :supply_position, SupplyPosition
belongs_to :invoice, FullCircle.Billing.Invoice  # null until Task 8
has_many :employees, through: [:trip_drop_employees, :employee]  # many workers per drop

# Join tables
# trading_trip_load_employees (trip_load_id, employee_id) unique pair
# trading_trip_drop_employees (trip_drop_id, employee_id) unique pair
```

**Pay qty (full participation in Trading):** each employee on a load/drop is recorded with that line’s full `actual_mt` in the employee load/drop register. **Loading/dropping salary and any split among workers are handled in Payroll**, not Trading.

**Changeset rules:**
- `location_id` required on load and drop
- `transport_mode` required; if `agent`, warn (not hard error) if agent blank on complete
- On `complete_trip/3`: status → completed; require actual_mt on lines (or default actual = planned with warning — prefer require actuals)
- Cancel completed: error if any drop has `invoice_id`; else status cancelled
- Validate one good on trip matches sales/supply goods when linked (warn or error — prefer **error** if mismatched good ids)
- Cast embeds/assocs with `cast_assoc` for loads/drops

**Balance queries (completed only):**

```elixir
def supply_loaded(supply_id) do
  from(l in TripLoad,
    join: t in Trip, on: t.id == l.trip_id,
    where: t.status == "completed" and l.supply_position_id == ^supply_id,
    select: coalesce(sum(l.actual_mt), 0)
  ) |> Repo.one()
end
```

Similar for sales_delivered, own_warehouse_qty(location_id).

**Warn helpers (return list of strings, do not block save):**
- remaining < 0 after complete
- abs(sum load actual − sum drop actual) > 0
- company_own complete with empty employee lists on load/drop (warn only)
- agent mode missing agent

Store warnings in flash or show on form; still allow complete.

**Tests (critical):**
1. Supply 100; load actual 40 complete → remaining 60  
2. Sales 35; drop actual 33.5 → undelivered 1.5; fulfill allowed  
3. Multi-load multi-drop math  
4. Own warehouse: drop into own_warehouse location then load out  
5. Draft trip does not affect remaining  
6. Soft hold still does not reduce remaining  
7. Cancel completed without invoice restores remaining  

**Routes:**

```elixir
live "/trading/trips", TradingTripLive.Index, :index
live "/trading/trips/new", TradingTripLive.Form, :new
live "/trading/trips/:id/edit", TradingTripLive.Form, :edit
```

Form: header fields; dynamic load/drop lines (add/remove); location selects filtered by company; complete/cancel buttons.

- [ ] TDD balances + trip context first, then LiveView.  
- [ ] Commit `feat(trading): trips multi-load multi-drop with balance updates`

---

### Task 7: Employee load/drop registers + agent delivery register

**Files:**
- Modify: `trading.ex` — query functions
- Create: `lib/full_circle_web/live/trading_employee_register_live/index.ex` (tabs or mode: load | drop)
- Create: `lib/full_circle_web/live/trading_agent_register_live/index.ex`
- Router + nav + tests

**Interfaces:**

```elixir
@spec employee_load_register(company, user, %{from: Date.t(), to: Date.t(), employee_id: id | nil}) ::
  [%{employee, trip, date, location, supply_position, actual_mt}]
  # one row per (employee, load line); actual_mt = full load.actual_mt (participation)

@spec employee_drop_register(company, user, filters) ::
  [%{employee, trip, date, location, sales_position, actual_mt}]

@spec agent_delivery_register(company, user, filters) ::
  [%{agent, trip, date, from_location, to_location, supply_position, sales_position, actual_mt}]
```

Agent rows: one per **drop** on completed trips with `transport_mode == "agent"`.  
`from_location`: resolve from a load on same trip sharing `supply_position_id` with the drop when possible; else first load location on trip (document choice in code comment).  
Totals by employee / by agent / by from→to pair.

**Tests:** three employees on one load each get full MT; two on drop each get full MT; agent O–D columns; date filter.

- [ ] Implement + commit `feat(trading): employee and agent delivery registers`

---

### Task 8: Settlement — Create Invoice / PurInvoice links

**Files:**
- Modify: `trading.ex`, `trip_drop.ex` (invoice_id already), supply may get `pur_invoice_id` optional column migration
- LiveView buttons on open sales detail / trip form / drop row
- Test: `test/full_circle/trading/settlement_test.exs`

**Behavior:**
- `create_invoice_from_drop(drop_id, company, user)`  
  - Auth: existing `can?(user, :create_invoice, company)` **and** `:manage_trading`  
  - Build attrs for `FullCircle.Billing.create_invoice/3` from sales position customer, good, unit_price, qty = drop.actual_mt  
  - Read a real invoice create call in `billing.ex` / invoice LiveView to match required attrs (tax code, accounts, doc dates) — **do not invent GL accounts**; reuse company defaults or require minimal fields the form requires  
  - On success set `trip_drops.invoice_id`  
  - If already linked, return `{:error, :already_invoiced}`

- `create_pur_invoice_from_supply_receipt(...)` similarly using `create_pur_invoice` for a chosen load/supply actual — only if attrs can be satisfied; if Billing requires too many fields for a thin API, implement a **guided navigate** to PurInvoice form with query params prefilled (document which approach works after reading Billing). Prefer in-context create if feasible.

**Tests:** after complete drop, create invoice links id; second call errors; drop qty on invoice line matches actual.

- [ ] Commit `feat(trading): settle drops to Invoice (and pur invoice path)`

---

### Task 9: Phase polish gate (minimal)

**Files:** as needed

- Variance note required when `|planned - actual| / planned > 0.02` (2%) on complete — implement if not already in Task 6  
- Empty states / gettext pass  
- `mix compile --warnings-as-errors` and targeted `mix test test/full_circle/trading test/full_circle_web/live/trading`

- [ ] Commit `test(trading): gate suite for grain trading desk v1 core`

---

## Spec coverage checklist

| Spec area | Task(s) |
|-----------|---------|
| Location master; not contact mail | 1–2, 6 |
| Driver / TransportAgent | 1–2, 7 |
| SupplyPosition no type; reference_no | 3–4 |
| Position board remaining / soft_held | 3–5, 6 |
| SalesPosition parent; soft hold; manual fulfill | 5 |
| Trip loads/drops; multi location; modes | 6 |
| Load/drop drivers; load+drop salary qty | 6–7 |
| Agent from→to Location + MT | 7 |
| Warn-only oversell / mismatches | 6 |
| Invoice/PurInvoice office settlement | 8 |
| Grain only; desktop | all |
| Phase 6 extras (DO print, rates, attachments) | **out of this plan** (follow-up) |

## Out of this plan (spec Phase 6+)

- DO print, weighbridge attachments  
- Driver rate tables / payroll  
- Agent PurInvoice auto-generation  
- Mileage matrix  
- Mobile app  

---

## Execution notes for agents

1. Always `cd` to `full_circle` repo before git/mix.  
2. Match existing fixture style (`FullCircle.SysFixtures` / accounting fixtures — discover via `test/support/fixtures`).  
3. Good module name: run `rg "defmodule FullCircle.*Good" lib`.  
4. Nav: if no global sidebar, add links on `TradingPositionBoardLive` as a local subnav component shared across trading LiveViews (`TradingNav` function component) to avoid hunting layout.  
5. Prefer Decimal for all MT/money math; never floats.
