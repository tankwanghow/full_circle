defmodule FullCircleWeb.TradingTripLive.Index do
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
       |> assign(page_title: gettext("Trips"))
       |> assign(:trips, Trading.list_trips(company, user))}
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
          :if={Authorization.can?(@current_user, :manage_trading, @current_company)}
          navigate={~p"/companies/#{@current_company.id}/trading/trips/new"}
          class="blue button"
          id="new_trip"
        >
          {gettext("New Trip")}
        </.link>
        <.link
          navigate={~p"/companies/#{@current_company.id}/trading/position_board"}
          class="teal button"
        >
          {gettext("Position Board")}
        </.link>
        <.link
          navigate={~p"/companies/#{@current_company.id}/trading/open_sales"}
          class="teal button"
        >
          {gettext("Open Sales")}
        </.link>
      </div>
      <div class="bg-amber-200 border-y-2 border-amber-500 font-bold p-2 grid grid-cols-8 gap-1 text-sm">
        <div>{gettext("Date")}</div>
        <div>{gettext("Ref")}</div>
        <div>{gettext("Vehicle")}</div>
        <div>{gettext("Good")}</div>
        <div>{gettext("Mode")}</div>
        <div class="text-center">{gettext("Loads")}</div>
        <div class="text-center">{gettext("Drops")}</div>
        <div>{gettext("Status")}</div>
      </div>
      <div id="trips_list">
        <div
          :for={t <- @trips}
          id={"trip-#{t.id}"}
          class="grid grid-cols-8 gap-1 border-b p-2 text-sm hover:bg-gray-100 dark:hover:bg-zinc-800"
        >
          <div>
            <.link
              navigate={~p"/companies/#{@current_company.id}/trading/trips/#{t.id}/edit"}
              class="text-blue-600"
            >
              {t.date}
            </.link>
          </div>
          <div>{t.reference_no || "—"}</div>
          <div>{t.vehicle_number || "—"}</div>
          <div>
            {t
             |> FullCircle.Trading.Trip.goods()
             |> Enum.map(& &1.name)
             |> Enum.join(", ")
             |> then(fn s -> if s == "", do: "—", else: s end)}
          </div>
          <div>{t.transport_mode}</div>
          <div class="text-center">{length(t.loads || [])}</div>
          <div class="text-center">{length(t.drops || [])}</div>
          <div>{t.status}</div>
        </div>
      </div>
      <p :if={@trips == []} class="text-center p-4 text-gray-500">
        {gettext("No trips yet.")}
      </p>
    </div>
    """
  end
end
