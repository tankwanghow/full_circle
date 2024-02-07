defmodule FullCircleWeb.HolidayLive.IndexComponent do
  use FullCircleWeb, :live_component

  @impl true
  def mount(socket) do
    {:ok, socket}
  end

  @impl true
  def update(assigns, socket) do
    {:ok, socket |> assign(assigns)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class={"#{@ex_class} text-center bg-gray-200 border-gray-500 hover:bg-gray-300 border-b p-1"}>
      <.link
        class="hover:font-bold text-blue-600"
        navigate={~p"/companies/#{@current_company.id}/holidays/#{@obj.id}/edit"}
      >
        <%= @obj.name %>
      </.link>
      &#8226; <%= @obj.short_name %> &#8226; <%= @obj.holidate |> FullCircleWeb.Helpers.format_date() %>
      <.link
        navigate={~p"/companies/#{@current_company}/holidays/#{@obj.id}/copy"}
        class="text-xs hover:bg-orange-400 bg-orange-200 py-1 px-2 rounded-full border-orange-400 border"
      >
        <%= gettext("Copy") %>
      </.link>
    </div>
    """
  end
end
