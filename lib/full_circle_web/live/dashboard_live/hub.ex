defmodule FullCircleWeb.DashboardLive.Hub do
  use FullCircleWeb, :live_view

  alias FullCircleWeb.DashboardLive.Menu

  @impl true
  def mount(%{"hub" => hub}, _session, socket) do
    role = socket.assigns.current_role
    user = socket.assigns.current_user
    company = socket.assigns.current_company

    if Menu.valid_hub_id?(hub, user, company, role) do
      title = Menu.hub_title(hub, user, company, role)
      links = Menu.links_for(hub, user, company, role)

      {:ok,
       socket
       |> assign(:hub, hub)
       |> assign(:page_title, title)
       |> assign(:links, links)
       |> assign(:back_to_route, ~p"/companies/#{company.id}/dashboard")}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("Menu not found"))
       |> push_navigate(to: ~p"/companies/#{company.id}/dashboard")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto w-11/12 md:w-8/12 max-w-4xl">
      <div class="mb-4 flex items-center justify-between gap-2">
        <.link
          navigate={~p"/companies/#{@current_company.id}/dashboard"}
          class="button gray"
        >
          {gettext("← Dashboard")}
        </.link>
        <p class="text-2xl md:text-3xl font-medium text-center flex-1">{@page_title}</p>
        <span class="w-24"></span>
      </div>

      <div class="mb-6 gap-2 flex flex-wrap justify-center">
        <.link
          :for={link <- @links}
          navigate={"/companies/#{@current_company.id}/#{link.path}"}
          class={link.class}
        >
          {link.label}
        </.link>
      </div>

      <p :if={@links == []} class="text-center text-gray-500 dark:text-gray-400">
        {gettext("No items available for your role.")}
      </p>
    </div>
    """
  end
end
