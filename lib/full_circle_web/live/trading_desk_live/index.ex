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
      {:ok,
       socket
       |> assign(page_title: gettext("Trading Desk"))
       |> assign(modal: nil)
       |> assign(can_manage: Authorization.can?(user, :manage_trading, company))
       |> load_panels()}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("You are not authorised to perform this action"))
       |> push_navigate(to: ~p"/companies/#{company.id}/dashboard")}
    end
  end

  @impl true
  def handle_event("open_modal", %{"kind" => kind, "action" => action} = params, socket) do
    company = socket.assigns.current_company
    user = socket.assigns.current_user

    if Authorization.can?(user, :manage_trading, company) do
      modal = %{
        kind: String.to_existing_atom(kind),
        action: String.to_existing_atom(action),
        id: params["id"]
      }

      {:noreply, assign(socket, modal: modal)}
    else
      {:noreply,
       put_flash(socket, :error, gettext("You are not authorised to perform this action"))}
    end
  end

  def handle_event("close_modal", _params, socket) do
    {:noreply, assign(socket, modal: nil)}
  end

  @impl true
  def handle_info({:desk_modal_saved, kind}, socket) do
    msg =
      case kind do
        :supply -> gettext("Supply position saved successfully.")
        :sales -> gettext("Sales position saved successfully.")
        _ -> gettext("Saved successfully.")
      end

    {:noreply,
     socket
     |> assign(modal: nil)
     |> put_flash(:info, msg)
     |> load_panels()}
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

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto w-11/12">
      <p class="w-full text-3xl text-center font-medium">{@page_title}</p>
      <div class="text-center mb-3 gap-1 flex flex-wrap justify-center">
        <button
          :if={@can_manage}
          type="button"
          id="desk-new-supply"
          phx-click="open_modal"
          phx-value-kind="supply"
          phx-value-action="new"
          class="blue button"
        >
          {gettext("New Supply")}
        </button>
        <button
          :if={@can_manage}
          type="button"
          id="desk-new-sales"
          phx-click="open_modal"
          phx-value-kind="sales"
          phx-value-action="new"
          class="blue button"
        >
          {gettext("New Sales")}
        </button>
        <.link
          navigate={~p"/companies/#{@current_company.id}/trading/position_board"}
          class="blue button"
        >
          {gettext("Position Board")}
        </.link>
        <.link
          navigate={~p"/companies/#{@current_company.id}/trading/warehouse_board"}
          class="blue button"
        >
          {gettext("Warehouse Board")}
        </.link>
        <.link
          navigate={~p"/companies/#{@current_company.id}/trading/open_sales"}
          class="blue button"
        >
          {gettext("Open Sales")}
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/trading/trips"} class="blue button">
          {gettext("Trips")}
        </.link>
      </div>

      <div class="flex flex-col lg:flex-row gap-3">
        <div class="lg:w-1/2 flex flex-col gap-3">
          <%!-- SUPPLY --%>
          <div id="desk_supply">
            <p class="font-semibold text-lg mb-1">{gettext("Supply")}</p>
            <div class="bg-amber-200 border-y-2 border-amber-500 font-bold p-2 flex gap-1 text-xs md:text-sm">
              <div class="w-4/12">{gettext("Supply")}</div>
              <div class="w-2/12">{gettext("Status")}</div>
              <div class="w-2/12 text-right">{gettext("Remaining")}</div>
              <div class="w-2/12 text-right">{gettext("Soft-held")}</div>
              <div class="w-1/12 text-center">{gettext("Unit")}</div>
              <div class="w-1/12 text-right">{gettext("Price")}</div>
            </div>
            <div
              :for={row <- @supply_rows}
              id={"desk-supply-#{row.supply.id}"}
              phx-click={if @can_manage, do: "open_modal"}
              phx-value-kind="supply"
              phx-value-action="edit"
              phx-value-id={row.supply.id}
              class={[
                "flex gap-1 border-b p-2 text-xs md:text-sm hover:bg-gray-100 dark:hover:bg-zinc-800",
                @can_manage && "cursor-pointer"
              ]}
            >
              <div class="w-4/12 text-blue-600">
                {row.supply.title || "—"}
              </div>
              <div class="w-2/12">{row.supply.status}</div>
              <div class={[
                "w-2/12 text-right font-semibold",
                remaining_class(row.remaining)
              ]}>
                {row.remaining}
              </div>
              <div class="w-2/12 text-right">{row.soft_held}</div>
              <div class="w-1/12 text-center">
                {row.supply.good && row.supply.good.unit}
              </div>
              <div class="w-1/12 text-right">{row.supply.unit_price}</div>
            </div>
            <p :if={@supply_rows == []} class="text-center p-3 text-gray-500 text-sm">
              {gettext("No open supply positions.")}
            </p>
          </div>

          <%!-- WAREHOUSE --%>
          <div id="desk_warehouse" class="border-t pt-3">
            <p class="font-semibold text-lg mb-1">{gettext("Warehouse")}</p>
            <div class="bg-amber-200 border-y-2 border-amber-500 font-bold p-2 flex gap-1 text-xs md:text-sm">
              <div class="w-4/12">{gettext("Warehouse")}</div>
              <div class="w-2/12 text-right">{gettext("In")}</div>
              <div class="w-2/12 text-right">{gettext("Out")}</div>
              <div class="w-2/12 text-right">{gettext("On hand")}</div>
            </div>
            <div
              :for={row <- @warehouse_rows}
              id={"desk-wh-#{row.location.id}"}
              class="flex gap-1 border-b p-2 text-xs md:text-sm hover:bg-gray-100 dark:hover:bg-zinc-800"
            >
              <div class="w-4/12">
                <.link
                  navigate={
                    ~p"/companies/#{@current_company.id}/trading/locations/#{row.location.id}/edit"
                  }
                  class="text-blue-600"
                >
                  {row.location.name}
                </.link>
              </div>
              <div class="w-2/12 text-right">{row.inbound}</div>
              <div class="w-2/12 text-right">{row.outbound}</div>
              <div class={[
                "w-2/12 text-right font-semibold",
                on_hand_class(row.on_hand)
              ]}>
                {row.on_hand}
              </div>
            </div>
            <p :if={@warehouse_rows == []} class="text-center p-3 text-gray-500 text-sm">
              {gettext("No own-warehouse locations yet.")}
            </p>
          </div>
        </div>

        <%!-- OPEN SALES --%>
        <div class="lg:w-1/2" id="desk_sales">
          <p class="font-semibold text-lg mb-1">{gettext("Open Sales")}</p>
          <div class="bg-amber-200 border-y-2 border-amber-500 font-bold p-2 flex gap-1 text-xs md:text-sm">
            <div class="w-3/12">{gettext("Sales")}</div>
            <div class="w-3/12">{gettext("Customer")}</div>
            <div class="w-2/12 text-right">{gettext("Undelivered")}</div>
            <div class="w-2/12">{gettext("Preferred supply")}</div>
            <div class="w-2/12">{gettext("Status")}</div>
          </div>
          <div
            :for={row <- @sales_rows}
            id={"desk-sales-#{row.sales.id}"}
            phx-click={if @can_manage, do: "open_modal"}
            phx-value-kind="sales"
            phx-value-action="edit"
            phx-value-id={row.sales.id}
            class={[
              "flex gap-1 border-b p-2 text-xs md:text-sm hover:bg-gray-100 dark:hover:bg-zinc-800",
              @can_manage && "cursor-pointer"
            ]}
          >
            <div class="w-3/12 text-blue-600">
              {row.sales.title || "—"}
            </div>
            <div class="w-3/12">{row.sales.customer && row.sales.customer.name}</div>
            <div class={[
              "w-2/12 text-right font-semibold",
              undelivered_class(row.undelivered)
            ]}>
              {row.undelivered}
            </div>
            <div class="w-2/12">
              {row.sales.preferred_supply && (row.sales.preferred_supply.title || "—")}
            </div>
            <div class="w-2/12">{row.sales.status}</div>
          </div>
          <p :if={@sales_rows == []} class="text-center p-3 text-gray-500 text-sm">
            {gettext("No open sales commitments.")}
          </p>
        </div>
      </div>

      <%!-- TRIPS --%>
      <div class="mt-3" id="desk_trips">
        <p class="font-semibold text-lg mb-1">{gettext("Trips")}</p>
        <div class="bg-amber-200 border-y-2 border-amber-500 font-bold p-2 flex gap-1 text-xs md:text-sm">
          <div class="w-2/14">{gettext("Date")}</div>
          <div class="w-2/14">{gettext("Ref")}</div>
          <div class="w-3/14">{gettext("Good")}</div>
          <div class="w-2/14">{gettext("Mode")}</div>
          <div class="w-2/14">{gettext("Status")}</div>
          <div class="w-1/14 text-center">{gettext("Loads")}</div>
          <div class="w-1/14 text-center">{gettext("Drops")}</div>
        </div>
        <div
          :for={t <- @trips}
          id={"desk-trip-#{t.id}"}
          class="flex gap-1 border-b p-2 text-xs md:text-sm hover:bg-gray-100 dark:hover:bg-zinc-800"
        >
          <div class="w-2/14">
            <.link
              navigate={~p"/companies/#{@current_company.id}/trading/trips/#{t.id}/edit"}
              class="text-blue-600"
            >
              {t.date}
            </.link>
          </div>
          <div class="w-2/14">{t.reference_no || "—"}</div>
          <div class="w-3/14">{t.good && t.good.name}</div>
          <div class="w-2/14">{t.transport_mode}</div>
          <div class="w-2/14">{t.status}</div>
          <div class="w-1/14 text-center">{length(t.loads || [])}</div>
          <div class="w-1/14 text-center">{length(t.drops || [])}</div>
        </div>
        <p :if={@trips == []} class="text-center p-3 text-gray-500 text-sm">
          {gettext("No trips yet.")}
        </p>
      </div>

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
        <.live_component
          :if={@modal.kind == :sales}
          module={FullCircleWeb.TradingDeskLive.SalesFormComponent}
          id="desk-sales-form-lc"
          company={@current_company}
          user={@current_user}
          action={@modal.action}
          sales_id={@modal.id}
        />
      </.modal>
    </div>
    """
  end

  defp remaining_class(remaining) do
    if Decimal.compare(remaining, 0) == :lt do
      "text-red-600"
    else
      ""
    end
  end

  defp on_hand_class(nil), do: "text-gray-500"

  defp on_hand_class(qty) do
    case Decimal.compare(qty, Decimal.new(0)) do
      :lt -> "text-red-600"
      :eq -> "text-gray-500"
      :gt -> ""
    end
  end

  defp undelivered_class(nil), do: ""

  defp undelivered_class(qty) do
    if Decimal.compare(qty, Decimal.new(0)) == :gt do
      "text-amber-700"
    else
      ""
    end
  end
end
