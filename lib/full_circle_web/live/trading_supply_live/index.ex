defmodule FullCircleWeb.TradingSupplyLive.Index do
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
       |> assign(page_title: gettext("Supply Positions"))
       |> assign(:supplies, Trading.list_supply_positions(company, user))}
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
          :if={Authorization.can?(@current_user, :manage_trading, @current_company)}
          navigate={~p"/companies/#{@current_company.id}/trading/supply_positions/new"}
          class="blue button"
          id="new_supply"
        >
          {gettext("New Supply")}
        </.link>
        <.link
          navigate={~p"/companies/#{@current_company.id}/trading/position_board"}
          class="teal button"
        >
          {gettext("Position Board")}
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/dashboard"} class="gray button">
          {gettext("Dashboard")}
        </.link>
      </div>
      <div class="bg-amber-200 border-y-2 border-amber-500 font-bold p-2 grid grid-cols-8 gap-1 text-sm">
        <div>{gettext("Name / ref")}</div>
        <div>{gettext("Available")}</div>
        <div>{gettext("Supplier")}</div>
        <div>{gettext("Good")}</div>
        <div class="text-right">{gettext("Qty")}</div>
        <div class="text-center">{gettext("Unit")}</div>
        <div>{gettext("Status")}</div>
        <div></div>
      </div>
      <div id="supplies_list">
        <div
          :for={s <- @supplies}
          id={"supply-#{s.id}"}
          class="grid grid-cols-8 gap-1 border-b p-2 text-sm hover:bg-gray-100 dark:hover:bg-zinc-800"
        >
          <div>
            <.link
              navigate={~p"/companies/#{@current_company.id}/trading/supply_positions/#{s.id}/edit"}
              class="text-blue-600"
            >
              {s.title || "—"}
            </.link>
          </div>
          <div>{s.available_from}</div>
          <div>{s.supplier && s.supplier.name}</div>
          <div>{s.good && s.good.name}</div>
          <div class="text-right">{s.quantity}</div>
          <div class="text-center font-medium">{s.good && s.good.unit}</div>
          <div>{s.status}</div>
          <div></div>
        </div>
      </div>
      <p :if={@supplies == []} class="text-center p-4 text-gray-500">{gettext("No supply positions yet.")}</p>
    </div>
    """
  end
end
