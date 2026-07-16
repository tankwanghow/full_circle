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
    <div class="mx-auto w-11/12">
      <p class="w-full text-3xl text-center font-medium">{@page_title}</p>
      <div class="text-center mb-3 gap-1 flex flex-wrap justify-center">
        <.link
          navigate={~p"/companies/#{@current_company.id}/trading/supply_positions"}
          class="blue button"
        >
          {gettext("Supply Positions")}
        </.link>
        <.link
          :if={Authorization.can?(@current_user, :manage_trading, @current_company)}
          navigate={~p"/companies/#{@current_company.id}/trading/supply_positions/new"}
          class="blue button"
        >
          {gettext("New Supply")}
        </.link>
      </div>

      <div class="overflow-x-auto">
        <div class="bg-amber-200 border-y-2 border-amber-500 font-bold p-2 grid grid-cols-10 gap-1 text-xs md:text-sm min-w-[960px]">
          <div>{gettext("Supply")}</div>
          <div>{gettext("Available")}</div>
          <div>{gettext("Supplier")}</div>
          <div>{gettext("Good")}</div>
          <div class="text-center">{gettext("Unit")}</div>
          <div class="text-right">{gettext("Contracted")}</div>
          <div class="text-right">{gettext("Loaded")}</div>
          <div class="text-right">{gettext("Remaining")}</div>
          <div class="text-right">{gettext("Soft-held")}</div>
          <div class="text-right">{gettext("Price")}</div>
        </div>
        <div id="position_board" class="min-w-[960px]">
          <div
            :for={row <- @rows}
            id={"board-#{row.supply.id}"}
            class="grid grid-cols-10 gap-1 border-b p-2 text-xs md:text-sm hover:bg-gray-100 dark:hover:bg-zinc-800"
          >
            <div>
              <.link
                navigate={
                  ~p"/companies/#{@current_company.id}/trading/supply_positions/#{row.supply.id}/edit"
                }
                class="text-blue-600"
              >
                {display_supply(row.supply)}
              </.link>
            </div>
            <div>{row.supply.available_from}</div>
            <div>{row.supply.supplier && row.supply.supplier.name}</div>
            <div>{row.supply.good && row.supply.good.name}</div>
            <div class="text-center font-medium">
              {row.supply.good && row.supply.good.unit}
            </div>
            <div class="text-right">{row.supply.quantity}</div>
            <div class="text-right">{row.loaded}</div>
            <div class={[
              "text-right font-semibold",
              remaining_class(row.remaining)
            ]}>
              {row.remaining}
            </div>
            <div class="text-right">{row.soft_held}</div>
            <div class="text-right">{row.supply.unit_price}</div>
          </div>
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
