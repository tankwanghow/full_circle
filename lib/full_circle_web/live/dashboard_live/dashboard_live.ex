defmodule FullCircleWeb.DashboardLive do
  use FullCircleWeb, :live_view

  alias FullCircleWeb.DashboardLive.Menu

  @impl true
  def mount(_params, _session, socket) do
    role = socket.assigns.current_role
    user = socket.assigns.current_user
    company = socket.assigns.current_company

    {:ok,
     socket
     |> assign(:back_to_route, "#")
     |> assign(page_title: gettext("Dashboard"))
     |> assign(:hubs, Menu.hubs(user, company, role))
     |> assign(:quick_links, Menu.quick_links(user, company, role))}
  end

  @impl true
  def handle_params(_, _uri, socket) do
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <p class="w-full text-3xl text-center font-medium mb-4">{@page_title}</p>

    <div :if={@current_role != "punch_camera"} class="mx-auto w-11/12 md:w-10/12 max-w-5xl">
      <div :if={@quick_links != []} class="mb-8">
        <p class="font-medium text-xl text-center mb-2">{gettext("Daily")}</p>
        <div class="gap-1 flex flex-wrap justify-center">
          <.link
            :for={link <- @quick_links}
            navigate={"/companies/#{@current_company.id}/#{link.path}"}
            class={link.class}
          >
            {link.label}
          </.link>
        </div>
      </div>

      <p class="font-medium text-xl text-center mb-3">{gettext("Menus")}</p>
      <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-3 mb-8">
        <.link
          :for={hub <- @hubs}
          navigate={~p"/companies/#{@current_company.id}/dashboard/#{hub.id}"}
          class={[
            "block rounded-xl border-2 p-4 text-left shadow-sm transition hover:shadow-md",
            hub_card_class(hub.color)
          ]}
        >
          <div class="text-lg font-semibold mb-1">{hub.title}</div>
          <div class="text-sm opacity-80">{hub.blurb}</div>
        </.link>
      </div>
    </div>

    <div
      :if={FullCircle.Authorization.can?(@current_user, :create_time_attendence, @current_company)}
      class="mx-auto text-center mb-4"
    >
      <div class="font-bold">
        <.link navigate={~p"/companies/#{@current_company.id}/take_photo"} class="blue button">
          {gettext("Take A Photo")}
        </.link>
      </div>
      <div class="mt-5 font-bold">
        <.link navigate={~p"/companies/#{@current_company.id}/face_id"} class="blue button">
          {gettext("Face ID")}
        </.link>
      </div>
    </div>
    """
  end

  defp hub_card_class("teal"),
    do: "border-teal-500 bg-teal-50 dark:bg-teal-950/40 hover:border-teal-600"

  defp hub_card_class("blue"),
    do: "border-blue-500 bg-blue-50 dark:bg-blue-950/40 hover:border-blue-600"

  defp hub_card_class("orange"),
    do: "border-orange-500 bg-orange-50 dark:bg-orange-950/40 hover:border-orange-600"

  defp hub_card_class("red"),
    do: "border-red-500 bg-red-50 dark:bg-red-950/40 hover:border-red-600"

  defp hub_card_class("gray"),
    do: "border-zinc-400 bg-zinc-50 dark:bg-zinc-900/40 hover:border-zinc-500"

  defp hub_card_class(_),
    do: "border-zinc-400 bg-zinc-50 dark:bg-zinc-900/40"
end
