# Trading Desk UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One Trading Desk LiveView that shows supply + warehouse (left column), open sales (right), and trips (full width), with create/edit via modals so operators need not leave the desk.

**Architecture:** New `TradingDeskLive.Index` owns panel assigns and modal state. Panels call existing `FullCircle.Trading` board/list APIs. Forms are LiveComponents (or ported form logic) rendered inside `<.modal>`. Save/complete reloads panels in place. Layout: left column stacks supply then warehouse; right = open sales; bottom = trips.

**Tech Stack:** Phoenix LiveView 1.1, existing `FullCircle.Trading` context, `core_components` modal, flex + Tailwind, Gettext.

**Spec:** `docs/superpowers/specs/2026-07-16-trading-desk-ui-design.md`

## Global Constraints

- Reuse `Trading.position_board/2`, `warehouse_board/2`, `list_open_sales/2`, `list_trips/2` — no new balance math.
- Auth: `view_trading` to mount; `manage_trading` for create/edit/complete.
- Flex layouts (not CSS grid) for panel rows.
- Left column: **supply partition then warehouse partition**; right: open sales; bottom: trips full width.
- Trip modal large (`max-w-6xl` or `max-w-[90vw]`); supply/sales medium (`max-w-3xl`).
- Location modal **deferred** — link to `/trading/locations`.
- Good filter deferred to Task 4.
- Keep existing form routes; add desk as primary dashboard link.
- Work in `full_circle/`; commit one task at a time; `mise exec -- mix test …` after each task.
- Prefer `Decimal` for MT display; never invent GL/invoice logic.

## File Structure

| Path | Responsibility |
|------|----------------|
| `lib/full_circle_web/live/trading_desk_live/index.ex` | Desk LiveView: load panels, modal state, toolbar |
| `lib/full_circle_web/live/trading_desk_live/supply_form_component.ex` | Supply create/edit modal body |
| `lib/full_circle_web/live/trading_desk_live/sales_form_component.ex` | Sales create/edit modal body |
| `lib/full_circle_web/live/trading_desk_live/trip_form_component.ex` | Trip create/edit large modal body |
| `lib/full_circle_web/router.ex` | `live "/trading/desk", …` |
| `lib/full_circle_web/live/dashboard_live/dashboard_live.ex` | Trading → Desk first |
| `test/full_circle_web/live/trading_desk_live_test.exs` | Desk + modal smoke tests |

Reference form behaviour from:

- `lib/full_circle_web/live/trading_supply_live/form.ex`
- `lib/full_circle_web/live/trading_sales_live/form.ex`
- `lib/full_circle_web/live/trading_trip_live/form.ex`

Modal API: `lib/full_circle_web/components/core_components.ex` (`modal/1`, `max_w` attr, `show`, `on_cancel`).

---

### Task 1: Desk shell (read-only panels)

**Files:**

- Create: `lib/full_circle_web/live/trading_desk_live/index.ex`
- Create: `test/full_circle_web/live/trading_desk_live_test.exs`
- Modify: `lib/full_circle_web/router.ex` (inside company live_session)
- Modify: `lib/full_circle_web/live/dashboard_live/dashboard_live.ex`

**Interfaces:**

- Produces: route `/companies/:company_id/trading/desk`
- Produces: assigns `:supply_rows`, `:sales_rows`, `:warehouse_rows`, `:trips`, `:modal` (`nil` in this task)

- [ ] **Step 1: Failing LiveView test**

```elixir
# test/full_circle_web/live/trading_desk_live_test.exs
defmodule FullCircleWeb.TradingDeskLiveTest do
  use FullCircleWeb.ConnCase
  import Phoenix.LiveViewTest
  import FullCircle.SysFixtures
  import FullCircle.UserAccountsFixtures
  import FullCircle.TradingFixtures
  import FullCircle.BillingFixtures

  setup %{conn: conn} do
    user = user_fixture()
    company = company_fixture(user, %{})
    %{conn: log_in_user(conn, user), user: user, company: company}
  end

  test "desk shows supply warehouse sales and trips sections", %{
    conn: conn,
    company: company,
    user: user
  } do
    good = good_fixture(company, user)
    supply_position_fixture(company, user, %{"title" => "Desk supply A", "good_id" => good.id})
    location_fixture(company, user, %{"kind" => "own_warehouse", "name" => "Desk silo"})
    sales_position_fixture(company, user, %{"title" => "Desk sales B", "status" => "open", "good_id" => good.id})

    {:ok, _lv, html} = live(conn, ~p"/companies/#{company.id}/trading/desk")
    assert html =~ "Trading Desk"
    assert html =~ "Desk supply A"
    assert html =~ "Desk silo"
    assert html =~ "Desk sales B"
    assert html =~ "Trips"
  end
end
```

- [ ] **Step 2: Run test — expect FAIL** (no route / module)

```bash
cd full_circle && mise exec -- mix test test/full_circle_web/live/trading_desk_live_test.exs
```

- [ ] **Step 3: Router + dashboard**

Add inside the company authenticated live_session (near other trading routes):

```elixir
live("/trading/desk", TradingDeskLive.Index, :index)
```

In `dashboard_live.ex` Trading group, put **Trading Desk** first:

```elixir
<.link navigate={~p"/companies/#{@current_company.id}/trading/desk"} class="button teal">
  {gettext("Trading Desk")}
</.link>
```

- [ ] **Step 4: Implement `TradingDeskLive.Index` shell**

```elixir
defmodule FullCircleWeb.TradingDeskLive.Index do
  use FullCircleWeb, :live_view

  alias FullCircle.Trading
  alias FullCircle.Trading.Balances
  alias FullCircle.Authorization

  @impl true
  def mount(_params, _session, socket) do
    company = socket.assigns.current_company
    user = socket.assigns.current_user

    if Authorization.can?(user, :view_trading, company) do
      {:ok, socket |> assign(page_title: gettext("Trading Desk")) |> assign(modal: nil) |> load_panels()}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("You are not authorised to perform this action"))
       |> push_navigate(to: ~p"/companies/#{company.id}/dashboard")}
    end
  end

  defp load_panels(socket) do
    company = socket.assigns.current_company
    user = socket.assigns.current_user

    sales_rows =
      company
      |> Trading.list_open_sales(user)
      |> Enum.map(fn s ->
        %{
          sales: s,
          ordered: s.quantity,
          delivered: Balances.sales_delivered(s),
          undelivered: Balances.sales_undelivered(s)
        }
      end)

    trips =
      company
      |> Trading.list_trips(user)
      |> Enum.take(50)

    socket
    |> assign(:supply_rows, Trading.position_board(company, user))
    |> assign(:sales_rows, sales_rows)
    |> assign(:warehouse_rows, Trading.warehouse_board(company, user))
    |> assign(:trips, trips)
  end

  # render: toolbar (links only this task — no modal buttons yet, or disabled stubs)
  # layout:
  # <div class="flex flex-col lg:flex-row gap-3">
  #   <div class="lg:w-1/2 flex flex-col gap-3">
  #     <!-- SUPPLY partition -->
  #     <!-- WAREHOUSE partition (border-t or separate card) -->
  #   </div>
  #   <div class="lg:w-1/2"><!-- OPEN SALES --></div>
  # </div>
  # <div class="mt-3"><!-- TRIPS full width --></div>
  #
  # Each partition: amber header flex row + flex data rows (match position_board / warehouse_board columns)
end
```

Panel columns (minimum):

- **Supply:** title, status, remaining, soft_held, unit (from good), price  
- **Warehouse:** name, in, out, on_hand  
- **Sales:** title, customer, undelivered, preferred supply title, status  
- **Trips:** date, reference_no, good name, transport_mode, status, load count, drop count  

Empty states: short gettext messages.

- [ ] **Step 5: Tests green**

```bash
mise exec -- mix test test/full_circle_web/live/trading_desk_live_test.exs
```

- [ ] **Step 6: Commit**

```bash
git add lib/full_circle_web/live/trading_desk_live lib/full_circle_web/router.ex \
  lib/full_circle_web/live/dashboard_live/dashboard_live.ex \
  test/full_circle_web/live/trading_desk_live_test.exs
git commit -m "feat(trading): desk shell with supply, warehouse, sales, trips panels"
```

---

### Task 2: Supply & sales modals

**Files:**

- Create: `lib/full_circle_web/live/trading_desk_live/supply_form_component.ex`
- Create: `lib/full_circle_web/live/trading_desk_live/sales_form_component.ex`
- Modify: `lib/full_circle_web/live/trading_desk_live/index.ex`
- Modify: `test/full_circle_web/live/trading_desk_live_test.exs`

**Interfaces:**

- Modal assign: `%{kind: :supply | :sales, action: :new | :edit, id: nil | binary_id}`
- Components receive `id`, `company`, `user`, `action`, `record` (nil for new), `myself` parent via `send(self(), {:desk_saved, :supply})` or `phx-target={@parent}` — use **send to parent LiveView**:

```elixir
# In component after successful save:
send(self(), {:desk_modal_saved, :supply})
# Parent:
def handle_info({:desk_modal_saved, _kind}, socket) do
  {:noreply, socket |> assign(modal: nil) |> put_flash(:info, …) |> load_panels()}
end
```

LiveComponents run in parent process, so `send(self(), …)` reaches the LiveView. Confirm with a smoke test.

- [ ] **Step 1: Failing test — open new supply modal and save**

```elixir
test "create supply from desk modal appears on board", %{conn: conn, company: company, user: user} do
  contact = FullCircle.BillingFixtures.contact_fixture(company, user)
  good = good_fixture(company, user)

  {:ok, lv, _html} = live(conn, ~p"/companies/#{company.id}/trading/desk")

  lv |> element("#desk-new-supply") |> render_click()
  assert has_element?(lv, "#desk-modal")

  lv
  |> form("#desk-supply-form",
    supply_position: %{
      title: "Modal supply X",
      quantity: "50",
      unit_price: "1000",
      supplier_name: contact.name,
      good_name: good.name,
      status: "open"
    }
  )
  |> render_submit()

  html = render(lv)
  assert html =~ "Modal supply X"
  refute has_element?(lv, "#desk-modal")
end
```

(IDs may be adjusted to match implementation; keep `desk-new-supply` and form id stable.)

- [ ] **Step 2: Run — FAIL** (no button/modal)

- [ ] **Step 3: Modal open/close on desk**

```elixir
def handle_event("open_modal", %{"kind" => kind, "action" => action} = params, socket) do
  # require manage_trading for new/edit
  modal = %{
    kind: String.to_existing_atom(kind),
    action: String.to_existing_atom(action),
    id: params["id"]
  }
  {:noreply, assign(socket, modal: modal)}
end

def handle_event("close_modal", _, socket), do: {:noreply, assign(socket, modal: nil)}
```

Toolbar (if manage):

```heex
<button type="button" id="desk-new-supply" phx-click="open_modal"
  phx-value-kind="supply" phx-value-action="new" class="blue button">…</button>
```

Render:

```heex
<.modal
  :if={@modal}
  id="desk-modal"
  show
  max_w={if @modal.kind == :trip, do: "max-w-6xl", else: "max-w-3xl"}
  on_cancel={JS.push("close_modal")}
>
  <.live_component
    :if={@modal.kind == :supply}
    module={FullCircleWeb.TradingDeskLive.SupplyFormComponent}
    id="desk-supply-form-lc"
    company={@current_company}
    user={@current_user}
    action={@modal.action}
    supply_id={@modal.id}
  />
  <!-- sales similarly -->
</.modal>
```

Note: core `modal` starts `hidden` and uses `show_modal` on mount when `show` is true — set `show={true}`.

- [ ] **Step 4: SupplyFormComponent**

Port essentials from `TradingSupplyLive.Form`:

- Mount/update: load supply if edit via `Trading.get_supply_position!/3`
- Events: validate (autocomplete supplier/good), save, close/hold/collect status actions if edit
- Form id: `desk-supply-form`
- On `{:ok, _}` save: `send(self(), {:desk_modal_saved, :supply})`

- [ ] **Step 5: SalesFormComponent**

Port from `TradingSalesLive.Form` (customer/good/preferred supply typeahead, open/hold/fulfill/cancel).

Form id: `desk-sales-form`.  
On fulfill/cancel/save success: `send(self(), {:desk_modal_saved, :sales})`.

- [ ] **Step 6: Row click opens edit**

```heex
<div phx-click="open_modal" phx-value-kind="supply" phx-value-action="edit"
     phx-value-id={row.supply.id} class="cursor-pointer …">
```

- [ ] **Step 7: Parent handle_info + tests green**

```bash
mise exec -- mix test test/full_circle_web/live/trading_desk_live_test.exs
```

- [ ] **Step 8: Commit**

```bash
git commit -m "feat(trading): supply and sales modals on trading desk"
```

---

### Task 3: Trip large modal

**Files:**

- Create: `lib/full_circle_web/live/trading_desk_live/trip_form_component.ex`
- Modify: `lib/full_circle_web/live/trading_desk_live/index.ex`
- Modify: `test/full_circle_web/live/trading_desk_live_test.exs`

**Interfaces:**

- Modal kind `:trip`, `max_w="max-w-6xl"`
- Uses `Trading.create_trip/3`, `update_trip/4`, `complete_trip/3`, `cancel_trip/3`
- Loadable supplies: `list_supply_positions(…, statuses: SupplyPosition.loadable_statuses())`
- On any success: `send(self(), {:desk_modal_saved, :trip})` so **all** panels reload

- [ ] **Step 1: Failing test**

```elixir
test "desk new trip modal saves and lists trip", %{conn: conn, company: company, user: user} do
  good = good_fixture(company, user)
  supply = supply_position_fixture(company, user, %{"good_id" => good.id, "status" => "open", "title" => "S1"})
  load_loc = location_fixture(company, user, %{"kind" => "supplier_site"})
  drop_loc = location_fixture(company, user, %{"kind" => "own_warehouse"})

  {:ok, lv, _} = live(conn, ~p"/companies/#{company.id}/trading/desk")
  lv |> element("#desk-new-trip") |> render_click()
  assert has_element?(lv, "#desk-trip-form")

  lv
  |> form("#desk-trip-form",
    trip: %{
      date: "2026-07-25",
      transport_mode: "company_own",
      status: "draft",
      good_name: good.name,
      reference_no: "DESK-T1",
      loads: %{"0" => %{location_id: load_loc.id, supply_position_id: supply.id, planned_mt: "10", actual_mt: "10"}},
      drops: %{"0" => %{location_id: drop_loc.id, planned_mt: "10", actual_mt: "10"}}
    }
  )
  |> render_submit()

  assert render(lv) =~ "DESK-T1"
end
```

- [ ] **Step 2: Implement TripFormComponent**

Port from `TradingTripLive.Form`:

- Header: date, ref, transport_mode, status, good autocomplete, agent autocomplete  
- Dynamic loads/drops (add/remove via `Helpers.add_line` / `delete_line`)  
- Supply select options include status label (`Title (open)`)  
- Complete / cancel buttons when edit + allowed status  
- Form id: `desk-trip-form`  
- Initial new trip: one empty load + one empty drop like existing form  

- [ ] **Step 3: Wire toolbar + trip row open edit**

- [ ] **Step 4: Tests green + commit**

```bash
mise exec -- mix test test/full_circle_web/live/trading_desk_live_test.exs test/full_circle/trading/trip_test.exs
git commit -m "feat(trading): trip large modal on trading desk"
```

---

### Task 4: Polish gate

**Files:** as needed — desk index, dashboard, position_board links, optional good filter

- [ ] **Step 1: Cross-links**

From position board / warehouse board / open sales headers, add “Trading Desk” link.  
Dashboard: Desk first (if not already).

- [ ] **Step 2: Optional good filter (if time)**

Toolbar select of goods used in panels; filter:

```elixir
Enum.filter(supply_rows, &(&1.supply.good_id == good_id))
# sales by sales.good_id; trips by trip.good_id; warehouse unchanged (physical site not good-scoped in v1)
```

Skip if incomplete — mark deferred in commit message rather than half-done UI.

- [ ] **Step 3: Full trading LiveView suite**

```bash
mise exec -- mix test test/full_circle/trading test/full_circle_web/live/trading_desk_live_test.exs \
  test/full_circle_web/live/trading_trip_live_test.exs \
  test/full_circle_web/live/trading_warehouse_board_live_test.exs \
  test/full_circle_web/live/trading_position_board_live_test.exs \
  test/full_circle_web/live/trading_open_sales_live_test.exs
```

- [ ] **Step 4: Commit**

```bash
git commit -m "feat(trading): desk polish and nav links"
```

---

## Spec coverage checklist

| Spec item | Task |
|-----------|------|
| `/trading/desk` primary screen | 1 |
| Left: supply + warehouse partitions | 1 |
| Right: open sales | 1 |
| Bottom: trips | 1 |
| Flex rows | 1–3 |
| Dashboard desk link | 1 |
| Supply/sales modals | 2 |
| Trip large modal | 3 |
| Panel reload after save/complete | 2–3 |
| Location modal deferred | — (link only) |
| Good filter | 4 optional |
| Existing routes kept | all |

## Out of plan

- Location/GPS modal on desk  
- PubSub live multi-user refresh  
- Removing old index routes  
- Settlement from desk  

---

## Execution notes

1. Always `cd full_circle` and `mise exec --` for mix.  
2. Modal close: clear `@modal` in LiveView; do not only hide DOM.  
3. Autocomplete URLs: same as existing forms  
   `/list/companies/#{company_id}/#{user_id}/autocomplete?schema=…&name=`.  
4. Prefer copy-adapt form modules over shared inheritance — extract only if duplication hurts.  
5. After trip save, open supply status may become `collect` — desk supply panel must show updated status (load_panels).
