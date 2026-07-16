defmodule FullCircleWeb.TradingTransportAgentLive.Index do
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
       |> assign(page_title: gettext("Transport Agents"))
       |> assign(:agents, Trading.list_transport_agents(company, user))}
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
          navigate={~p"/companies/#{@current_company.id}/trading/transport_agents/new"}
          class="blue button"
          id="new_transport_agent"
        >
          {gettext("New Transport Agent")}
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/dashboard"} class="gray button">
          {gettext("Dashboard")}
        </.link>
      </div>
      <div class="bg-amber-200 border-y-2 border-amber-500 font-bold p-2 text-center">
        {gettext("Name / Phone / Active")}
      </div>
      <div id="agents_list">
        <div
          :for={a <- @agents}
          id={"agent-#{a.id}"}
          class="flex flex-row border-b p-2 hover:bg-gray-100 dark:hover:bg-zinc-800"
        >
          <.link
            navigate={~p"/companies/#{@current_company.id}/trading/transport_agents/#{a.id}/edit"}
            class="flex-1 text-blue-600"
          >
            {a.name}
          </.link>
          <div class="w-40">{a.phone}</div>
          <div class="w-20 text-center">{if(a.active, do: gettext("Yes"), else: gettext("No"))}</div>
        </div>
      </div>
      <p :if={@agents == []} class="text-center p-4 text-gray-500">{gettext("No transport agents yet.")}</p>
    </div>
    """
  end
end
