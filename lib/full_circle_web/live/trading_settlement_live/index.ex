defmodule FullCircleWeb.TradingSettlementLive.Index do
  use FullCircleWeb, :live_view

  alias FullCircle.Trading
  alias FullCircle.Authorization

  @impl true
  def mount(_params, _session, socket) do
    company = socket.assigns.current_company
    user = socket.assigns.current_user

    if Authorization.can?(user, :view_trading, company) do
      {:ok,
       socket
       |> assign(page_title: gettext("Trading Settlement — Customer Invoices"))
       |> assign(selected: MapSet.new())
       |> assign(modal: nil)
       |> assign(can_manage: Authorization.can?(user, :manage_trading, company))
       |> assign(can_invoice: Authorization.can?(user, :create_invoice, company))
       |> assign(filters: %{"customer_id" => "", "from_date" => "", "to_date" => ""})
       |> load_rows()}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("You are not authorised to perform this action"))
       |> push_navigate(to: ~p"/companies/#{company.id}/dashboard")}
    end
  end

  @impl true
  def handle_event("open_trip", %{"id" => id}, socket) do
    if socket.assigns.can_manage do
      {:noreply,
       assign(socket,
         modal: %{kind: :trip, action: :edit, id: id, form_key: id}
       )}
    else
      {:noreply,
       put_flash(socket, :error, gettext("You are not authorised to perform this action"))}
    end
  end

  def handle_event("close_modal", _params, socket) do
    {:noreply, assign(socket, modal: nil)}
  end

  def handle_event("toggle", %{"id" => id}, socket) do
    row = Enum.find(socket.assigns.rows, &(&1.id == id))

    if row && row.invoiceable do
      selected =
        if MapSet.member?(socket.assigns.selected, id) do
          MapSet.delete(socket.assigns.selected, id)
        else
          MapSet.put(socket.assigns.selected, id)
        end

      {:noreply, assign(socket, selected: selected)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("toggle_customer", %{"customer_id" => customer_id}, socket) do
    ids =
      socket.assigns.rows
      |> Enum.filter(&(&1.customer_id == customer_id and &1.invoiceable))
      |> Enum.map(& &1.id)

    all_selected? = ids != [] and Enum.all?(ids, &MapSet.member?(socket.assigns.selected, &1))

    selected =
      if all_selected? do
        Enum.reduce(ids, socket.assigns.selected, &MapSet.delete(&2, &1))
      else
        Enum.reduce(ids, socket.assigns.selected, &MapSet.put(&2, &1))
      end

    {:noreply, assign(socket, selected: selected)}
  end

  def handle_event("filter", %{"filters" => filters}, socket) do
    {:noreply,
     socket
     |> assign(filters: filters)
     |> assign(selected: MapSet.new())
     |> load_rows()}
  end

  def handle_event("create_invoice", _params, socket) do
    company = socket.assigns.current_company
    user = socket.assigns.current_user
    ids = MapSet.to_list(socket.assigns.selected)

    cond do
      not socket.assigns.can_invoice ->
        {:noreply,
         put_flash(socket, :error, gettext("You are not authorised to perform this action"))}

      ids == [] ->
        {:noreply, put_flash(socket, :error, gettext("Select at least one drop"))}

      true ->
        case Trading.build_invoice_attrs_from_drop_ids(ids, company, user) do
          {:ok, _attrs} ->
            {:noreply,
             push_navigate(socket,
               to:
                 ~p"/companies/#{company.id}/Invoice/new?#{%{trading_drops: Enum.join(ids, ",")}}"
             )}

          {:error, :mixed_customers} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               gettext("Selected drops must belong to the same customer")
             )}

          {:error, :ineligible_drops} ->
            {:noreply,
             socket
             |> put_flash(:error, gettext("Some drops are no longer eligible for invoicing"))
             |> assign(selected: MapSet.new())
             |> load_rows()}

          :not_authorise ->
            {:noreply,
             put_flash(socket, :error, gettext("You are not authorised to perform this action"))}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, gettext("Cannot create invoice from selection"))}
        end
    end
  end

  @impl true
  def handle_info({:desk_modal_saved, kind}, socket),
    do: handle_info({:desk_modal_saved, kind, nil}, socket)

  def handle_info({:desk_modal_saved, :trip, msg}, socket) do
    msg = msg || gettext("Trip saved.")

    {:noreply,
     socket
     |> put_flash(:info, msg)
     |> assign(modal: nil)
     |> load_rows()}
  end

  def handle_info({:desk_modal_saved, _kind, msg}, socket) do
    {:noreply,
     socket
     |> put_flash(:info, msg || gettext("Saved."))
     |> assign(modal: nil)
     |> load_rows()}
  end

  defp load_rows(socket) do
    company = socket.assigns.current_company
    user = socket.assigns.current_user
    filters = socket.assigns.filters

    opts =
      []
      |> maybe_opt(:customer_id, blank_to_nil(filters["customer_id"]))
      |> maybe_opt(:from_date, parse_date(filters["from_date"]))
      |> maybe_opt(:to_date, parse_date(filters["to_date"]))

    rows = Trading.list_uninvoiced_drops(company, user, opts)
    # Keep only valid selections after reload
    invoiceable_ids = rows |> Enum.filter(& &1.invoiceable) |> MapSet.new(& &1.id)

    selected =
      socket.assigns.selected
      |> MapSet.intersection(invoiceable_ids)

    groups = Enum.group_by(rows, &{&1.customer_id, &1.customer_name})

    socket
    |> assign(rows: rows)
    |> assign(selected: selected)
    |> assign(groups: groups)
  end

  defp maybe_opt(opts, _key, nil), do: opts
  defp maybe_opt(opts, key, val), do: Keyword.put(opts, key, val)

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(v), do: v

  defp parse_date(nil), do: nil
  defp parse_date(""), do: nil

  defp parse_date(str) when is_binary(str) do
    case Date.from_iso8601(str) do
      {:ok, d} -> d
      _ -> nil
    end
  end

  defp selected_total_mt(rows, selected) do
    rows
    |> Enum.filter(&MapSet.member?(selected, &1.id))
    |> Enum.reduce(Decimal.new(0), fn r, acc ->
      Decimal.add(acc, display_mt(r) || 0)
    end)
  end

  defp display_mt(%{actual_mt: %Decimal{} = a}), do: a
  defp display_mt(%{actual_mt: a}) when not is_nil(a), do: a
  defp display_mt(%{planned_mt: p}), do: p
  defp display_mt(_), do: Decimal.new(0)

  defp customer_options(rows) do
    rows
    |> Enum.map(&{&1.customer_name, &1.customer_id})
    |> Enum.uniq_by(fn {_n, id} -> id end)
    |> Enum.sort_by(fn {n, _} -> n end)
  end

  defp status_label("completed"), do: gettext("completed")
  defp status_label("planned"), do: gettext("planned")
  defp status_label("draft"), do: gettext("draft")
  defp status_label(other), do: other

  defp status_class("completed"), do: "bg-emerald-100 text-emerald-800"
  defp status_class("planned"), do: "bg-sky-100 text-sky-800"
  defp status_class("draft"), do: "bg-gray-100 text-gray-600"
  defp status_class(_), do: "bg-gray-100 text-gray-600"

  defp group_invoiceable_count(rows), do: Enum.count(rows, & &1.invoiceable)

  defp group_mt(rows) do
    Enum.reduce(rows, Decimal.new(0), fn r, a -> Decimal.add(a, display_mt(r) || 0) end)
  end

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        selected_count: MapSet.size(assigns.selected),
        selected_mt: selected_total_mt(assigns.rows, assigns.selected)
      )

    ~H"""
    <div class="mx-auto w-11/12 max-w-6xl">
      <p class="w-full text-3xl text-center font-medium">{@page_title}</p>
      <div class="text-center mb-3 flex flex-wrap gap-2 justify-center">
        <.link navigate={~p"/companies/#{@current_company.id}/trading/desk"} class="gray button">
          {gettext("Trading Desk")}
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/dashboard"} class="gray button">
          {gettext("Dashboard")}
        </.link>
      </div>

      <p class="text-sm text-center text-gray-600 mb-4">
        {gettext(
          "Sales drops on draft, planned, and completed trips (not yet invoiced). Only completed drops with actual MT can be selected for invoicing."
        )}
      </p>

      <.form
        for={%{}}
        as={:filters}
        id="settlement-filters"
        phx-change="filter"
        class="mb-4 flex flex-wrap gap-2 items-end justify-center text-sm"
      >
        <div>
          <label class="block text-xs font-medium">{gettext("Customer")}</label>
          <select name="filters[customer_id]" class="border rounded px-2 py-1 min-w-[12rem]">
            <option value="">{gettext("All customers")}</option>
            <option
              :for={{name, id} <- customer_options(@rows)}
              value={id}
              selected={@filters["customer_id"] == id}
            >
              {name}
            </option>
          </select>
        </div>
        <div>
          <label class="block text-xs font-medium">{gettext("From")}</label>
          <input
            type="date"
            name="filters[from_date]"
            value={@filters["from_date"]}
            class="border rounded px-2 py-1"
          />
        </div>
        <div>
          <label class="block text-xs font-medium">{gettext("To")}</label>
          <input
            type="date"
            name="filters[to_date]"
            value={@filters["to_date"]}
            class="border rounded px-2 py-1"
          />
        </div>
      </.form>

      <div class="flex flex-wrap gap-3 justify-center items-center mb-4">
        <span class="text-sm">
          {gettext("Selected")}: <strong>{@selected_count}</strong>
          · {gettext("MT")}: <strong>{@selected_mt}</strong>
        </span>
        <button
          :if={@can_invoice}
          type="button"
          phx-click="create_invoice"
          id="create-trading-invoice"
          class="blue button"
          disabled={@selected_count == 0}
        >
          {gettext("Create Invoice")}
        </button>
        <span :if={!@can_invoice} class="text-sm text-amber-700">
          {gettext("You need invoice permission to settle drops.")}
        </span>
      </div>

      <div :if={@rows == []} class="text-center text-gray-500 py-8 border rounded">
        {gettext("No sales deliveries to show.")}
      </div>

      <div
        :for={{{customer_id, customer_name}, group_rows} <- @groups}
        class="mb-6 border rounded overflow-hidden"
      >
        <div class="bg-amber-200 border-b border-amber-500 font-bold p-2 flex gap-2 items-center text-sm">
          <button
            :if={group_invoiceable_count(group_rows) > 0}
            type="button"
            phx-click="toggle_customer"
            phx-value-customer_id={customer_id}
            class="underline text-blue-800"
            id={"toggle-customer-#{customer_id}"}
          >
            {gettext("Toggle all billable")}
          </button>
          <span
            :if={group_invoiceable_count(group_rows) == 0}
            class="text-xs font-normal text-gray-600"
          >
            {gettext("None billable yet")}
          </span>
          <span class="flex-1">{customer_name}</span>
          <span class="font-normal text-xs">
            {group_invoiceable_count(group_rows)}/{length(group_rows)} {gettext("billable")} ·
            {group_mt(group_rows)} {gettext("MT")}
          </span>
        </div>
        <div class="bg-gray-100 font-semibold p-2 flex gap-1 text-xs border-b">
          <div class="w-8"></div>
          <div class="w-2/12">{gettext("Date")}</div>
          <div class="w-2/12">{gettext("Trip")}</div>
          <div class="w-1/12">{gettext("Status")}</div>
          <div class="w-2/12">{gettext("Sales")}</div>
          <div class="w-2/12">{gettext("Good")}</div>
          <div class="w-2/12">{gettext("Location")}</div>
          <div class="w-1/12 text-right">{gettext("MT")}</div>
          <div class="w-1/12 text-right">{gettext("Price")}</div>
        </div>
        <div
          :for={row <- group_rows}
          id={"uninvoiced-drop-#{row.id}"}
          class={[
            "flex gap-1 border-b p-2 text-sm items-center",
            row.invoiceable && "hover:bg-gray-50",
            !row.invoiceable && "opacity-60 bg-gray-50/80"
          ]}
        >
          <div class="w-8">
            <input
              :if={row.invoiceable}
              type="checkbox"
              phx-click="toggle"
              phx-value-id={row.id}
              checked={MapSet.member?(@selected, row.id)}
              id={"select-drop-#{row.id}"}
            />
            <span
              :if={!row.invoiceable}
              class="inline-block w-4 text-center text-gray-400"
              title={gettext("Complete the trip before invoicing")}
            >
              —
            </span>
          </div>
          <div class="w-2/12">{row.trip_date}</div>
          <div class="w-2/12 font-mono text-xs">
            <button
              :if={@can_manage}
              type="button"
              id={"open-trip-#{row.trip_id}"}
              phx-click="open_trip"
              phx-value-id={row.trip_id}
              class="text-blue-600 hover:underline font-medium text-left"
              title={gettext("Edit trip")}
            >
              {row.trip_reference_no}
            </button>
            <span :if={!@can_manage}>{row.trip_reference_no}</span>
          </div>
          <div class="w-1/12">
            <span class={["px-1.5 py-0.5 rounded text-xs font-medium", status_class(row.trip_status)]}>
              {status_label(row.trip_status)}
            </span>
          </div>
          <div class="w-2/12 font-mono text-xs">{row.sales_title}</div>
          <div class="w-2/12">{row.good_name}</div>
          <div class="w-2/12">{row.location_name}</div>
          <div class="w-1/12 text-right tabular-nums">
            {display_mt(row)}
            <span
              :if={is_nil(row.actual_mt) and not is_nil(row.planned_mt)}
              class="text-xs text-gray-400"
              title={gettext("Planned (no actual yet)")}
            >
              *
            </span>
          </div>
          <div class="w-1/12 text-right tabular-nums">{row.unit_price || "—"}</div>
        </div>
      </div>

      <.modal
        :if={@modal}
        id="settlement-trip-modal"
        show
        max_w="max-w-7xl"
        on_cancel={JS.push("close_modal")}
      >
        <.live_component
          :if={@modal.kind == :trip}
          module={FullCircleWeb.TradingDeskLive.TripFormComponent}
          id={"settlement-trip-form-lc-#{@modal[:form_key] || @modal[:id] || "new"}"}
          company={@current_company}
          user={@current_user}
          action={@modal.action}
          trip_id={@modal.id}
          prefill={@modal[:prefill]}
        />
      </.modal>
    </div>
    """
  end
end
