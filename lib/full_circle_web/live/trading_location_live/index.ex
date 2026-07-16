defmodule FullCircleWeb.TradingLocationLive.Index do
  use FullCircleWeb, :live_view

  alias FullCircle.Trading
  alias FullCircle.Trading.Location
  alias FullCircle.Authorization

  @impl true
  def mount(_params, _session, socket) do
    company = socket.assigns.current_company
    user = socket.assigns.current_user

    if Authorization.can?(user, :view_trading, company) do
      {:ok,
       socket
       |> assign(page_title: gettext("Trading Locations"))
       |> assign(:locations, Trading.list_locations(company, user))}
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
      <div class="text-center mb-3">
        <.link
          :if={Authorization.can?(@current_user, :manage_trading, @current_company)}
          navigate={~p"/companies/#{@current_company.id}/trading/locations/new"}
          class="blue button"
          id="new_location"
        >
          {gettext("New Location")}
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/dashboard"} class="gray button">
          {gettext("Dashboard")}
        </.link>
      </div>
      <div class="bg-amber-200 border-y-2 border-amber-500 font-bold p-2 flex gap-1 text-sm">
        <div class="w-3/12">{gettext("Name")}</div>
        <div class="w-2/12">{gettext("Kind")}</div>
        <div class="w-3/12">{gettext("GPS")}</div>
        <div class="w-2/12 text-center">{gettext("Map")}</div>
        <div class="w-2/12 text-center">{gettext("Active")}</div>
      </div>
      <div id="locations_list">
        <div
          :for={loc <- @locations}
          id={"location-#{loc.id}"}
          class="flex gap-1 border-b p-2 text-sm hover:bg-gray-100 dark:hover:bg-zinc-800"
        >
          <.link
            navigate={~p"/companies/#{@current_company.id}/trading/locations/#{loc.id}/edit"}
            class="w-3/12 text-blue-600"
          >
            {loc.name}
          </.link>
          <div class="w-2/12">{loc.kind}</div>
          <div class="w-3/12 font-mono text-xs">
            {Location.gps_label(loc) || "—"}
          </div>
          <div class="w-2/12 text-center">
            <a
              :if={Location.google_maps_url(loc)}
              href={Location.google_maps_url(loc)}
              target="_blank"
              rel="noopener noreferrer"
              class="text-blue-600 underline"
            >
              {gettext("Google Maps")}
            </a>
            <span :if={!Location.google_maps_url(loc)} class="text-gray-400">—</span>
          </div>
          <div class="w-2/12 text-center">
            {if(loc.active, do: gettext("Yes"), else: gettext("No"))}
          </div>
        </div>
      </div>
      <p :if={@locations == []} class="text-center p-4 text-gray-500">
        {gettext("No locations yet.")}
      </p>
    </div>
    """
  end
end
