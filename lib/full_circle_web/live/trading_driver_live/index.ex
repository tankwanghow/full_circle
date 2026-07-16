defmodule FullCircleWeb.TradingDriverLive.Index do
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
       |> assign(page_title: gettext("Trading Drivers"))
       |> assign(:drivers, Trading.list_drivers(company, user))}
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
      <div class="text-center mb-3">
        <.link
          :if={Authorization.can?(@current_user, :manage_trading, @current_company)}
          navigate={~p"/companies/#{@current_company.id}/trading/drivers/new"}
          class="blue button"
          id="new_driver"
        >
          {gettext("New Driver")}
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/dashboard"} class="gray button">
          {gettext("Dashboard")}
        </.link>
      </div>
      <div class="bg-amber-200 border-y-2 border-amber-500 font-bold p-2 text-center">
        {gettext("Name / Phone / Active")}
      </div>
      <div id="drivers_list">
        <div
          :for={d <- @drivers}
          id={"driver-#{d.id}"}
          class="flex flex-row border-b p-2 hover:bg-gray-100 dark:hover:bg-zinc-800"
        >
          <.link
            navigate={~p"/companies/#{@current_company.id}/trading/drivers/#{d.id}/edit"}
            class="flex-1 text-blue-600"
          >
            {d.name}
          </.link>
          <div class="w-40">{d.phone}</div>
          <div class="w-20 text-center">{if(d.active, do: gettext("Yes"), else: gettext("No"))}</div>
        </div>
      </div>
      <p :if={@drivers == []} class="text-center p-4 text-gray-500">{gettext("No drivers yet.")}</p>
    </div>
    """
  end
end
