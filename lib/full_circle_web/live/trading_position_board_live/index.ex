defmodule FullCircleWeb.TradingPositionBoardLive.Index do
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
       |> assign(page_title: gettext("Position Board"))
       |> assign(:rows, Trading.position_board(company, user))}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("You are not authorised to perform this action"))
       |> push_navigate(to: ~p"/companies/#{company.id}/dashboard")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto w-10/12">
      <p class="w-full text-3xl text-center font-medium">{@page_title}</p>
      <div class="text-center mb-3 gap-1 flex flex-wrap justify-center">
        <.link
          navigate={~p"/companies/#{@current_company.id}/trading/desk"}
          class="teal button"
        >
          {gettext("Trading Desk")}
        </.link>
        <.link
          navigate={~p"/companies/#{@current_company.id}/trading/supply_positions"}
          class="blue button"
        >
          {gettext("Supply Positions")}
        </.link>
        <.link
          navigate={~p"/companies/#{@current_company.id}/trading/warehouse_board"}
          class="blue button"
        >
          {gettext("Warehouse Board")}
        </.link>
        <.link
          navigate={~p"/companies/#{@current_company.id}/trading/trips"}
          class="blue button"
        >
          {gettext("Trips")}
        </.link>
        <.link
          navigate={~p"/companies/#{@current_company.id}/trading/open_sales"}
          class="blue button"
        >
          {gettext("Open Sales")}
        </.link>
        <.link
          :if={Authorization.can?(@current_user, :manage_trading, @current_company)}
          navigate={~p"/companies/#{@current_company.id}/trading/supply_positions/new"}
          class="blue button"
        >
          {gettext("New Supply")}
        </.link>
        <.link
          :if={Authorization.can?(@current_user, :manage_trading, @current_company)}
          navigate={~p"/companies/#{@current_company.id}/trading/sales_positions/new"}
          class="blue button"
        >
          {gettext("New Sales")}
        </.link>
      </div>

      <div class="bg-amber-200 border-y-2 border-amber-500 font-bold p-2 flex gap-1 text-xs md:text-sm">
        <div class="w-5/30">{gettext("Supply")}</div>
        <div class="w-2/30">{gettext("Status")}</div>
        <div class="w-2/30">{gettext("Available")}</div>
        <div class="w-5/30">{gettext("Supplier")}</div>
        <div class="w-4/30">{gettext("Good")}</div>
        <div class="w-2/30 text-center">{gettext("Unit")}</div>
        <div class="w-2/30 text-right">{gettext("Contracted")}</div>
        <div class="w-2/30 text-right">{gettext("Loaded")}</div>
        <div class="w-2/30 text-right">{gettext("Remaining")}</div>
        <div class="w-2/30 text-right">{gettext("Soft-held")}</div>
        <div class="w-2/30 text-right">{gettext("Price")}</div>
      </div>
      <div id="position_board">
        <div
          :for={row <- @rows}
          id={"board-#{row.supply.id}"}
          class="flex gap-1 border-b p-2 text-xs md:text-sm hover:bg-gray-100 dark:hover:bg-zinc-800"
        >
          <div class="w-5/30">
            <.link
              navigate={
                ~p"/companies/#{@current_company.id}/trading/supply_positions/#{row.supply.id}/edit"
              }
              class="text-blue-600"
            >
              {display_supply(row.supply)}
            </.link>
          </div>
          <div class="w-2/30">{row.supply.status}</div>
          <div class="w-2/30">{row.supply.available_from}</div>
          <div class="w-5/30">{row.supply.supplier && row.supply.supplier.name}</div>
          <div class="w-4/30">{row.supply.good && row.supply.good.name}</div>
          <div class="w-2/30 text-center font-medium">
            {row.supply.good && row.supply.good.unit}
          </div>
          <div class="w-2/30 text-right">{row.supply.quantity}</div>
          <div class="w-2/30 text-right">{row.loaded}</div>
          <div class={[
            "w-2/30 text-right font-semibold",
            remaining_class(row.remaining)
          ]}>
            {row.remaining}
          </div>
          <div class="w-2/30 text-right">{row.soft_held}</div>
          <div class="w-2/30 text-right">{row.supply.unit_price}</div>
        </div>
      </div>
      <p :if={@rows == []} class="text-center p-4 text-gray-500">
        {gettext("No open supply positions.")}
      </p>
    </div>
    """
  end

  defp display_supply(s) do
    s.title || "—"
  end

  defp remaining_class(remaining) do
    if Decimal.compare(remaining, 0) == :lt do
      "text-red-600"
    else
      ""
    end
  end
end
