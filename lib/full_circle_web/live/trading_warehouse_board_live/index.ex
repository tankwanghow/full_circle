defmodule FullCircleWeb.TradingWarehouseBoardLive.Index do
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
       |> assign(page_title: gettext("Warehouse Board"))
       |> assign(:rows, Trading.warehouse_board(company, user))}
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
    <div class="mx-auto w-8/12">
      <p class="w-full text-3xl text-center font-medium">{@page_title}</p>
      <p class="text-center text-sm text-gray-500 mb-2">
        {gettext("Own warehouse stock from completed trips (in − out).")}
      </p>
      <div class="text-center mb-3 gap-1 flex flex-wrap justify-center">
        <.link
          navigate={~p"/companies/#{@current_company.id}/trading/desk"}
          class="teal button"
        >
          {gettext("Trading Desk")}
        </.link>
        <.link
          navigate={~p"/companies/#{@current_company.id}/trading/position_board"}
          class="blue button"
        >
          {gettext("Position Board")}
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/trading/trips"} class="blue button">
          {gettext("Trips")}
        </.link>
        <.link
          navigate={~p"/companies/#{@current_company.id}/trading/locations"}
          class="teal button"
        >
          {gettext("Locations")}
        </.link>
        <.link
          :if={Authorization.can?(@current_user, :manage_trading, @current_company)}
          navigate={~p"/companies/#{@current_company.id}/trading/trips/new"}
          class="blue button"
        >
          {gettext("New Trip")}
        </.link>
      </div>

      <div class="bg-amber-200 border-y-2 border-amber-500 font-bold p-2 flex gap-1 text-sm">
        <div class="w-3/12">{gettext("Location")}</div>
        <div class="w-3/12">{gettext("Good")}</div>
        <div class="w-2/12 text-right">{gettext("In")}</div>
        <div class="w-2/12 text-right">{gettext("Out")}</div>
        <div class="w-2/12 text-right">{gettext("On hand")}</div>
      </div>
      <div id="warehouse_board">
        <div
          :for={row <- @rows}
          id={"wh-#{row.location.id}-#{row.good && row.good.id || "none"}"}
          class="flex gap-1 border-b p-2 text-sm hover:bg-gray-100 dark:hover:bg-zinc-800"
        >
          <div class="w-3/12 min-w-0 truncate">
            <.link
              navigate={
                ~p"/companies/#{@current_company.id}/trading/locations/#{row.location.id}/edit"
              }
              class="text-blue-600"
              title={row.location.name}
            >
              {row.location.name}
            </.link>
          </div>
          <div class="w-3/12 min-w-0 truncate" title={row.good && row.good.name}>
            {(row.good && row.good.name) || "—"}
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
      </div>
      <p :if={@rows == []} class="text-center p-4 text-gray-500">
        {gettext("No own-warehouse locations yet. Create one under Locations (kind: own_warehouse).")}
      </p>
    </div>
    """
  end

  defp on_hand_class(nil), do: "text-gray-500"

  defp on_hand_class(qty) do
    case Decimal.compare(qty, Decimal.new(0)) do
      :lt -> "text-red-600"
      :eq -> "text-gray-500"
      :gt -> ""
    end
  end
end

