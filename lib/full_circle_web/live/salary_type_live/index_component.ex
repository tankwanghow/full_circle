defmodule FullCircleWeb.SalaryTypeLive.IndexComponent do
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
    <div
      id={@id}
      class={"#{@ex_class} text-center mb-1 bg-gray-200 border-gray-500 border-2 rounded p-2"}
    >
      <.link
        class="text-blue-600 hover:font-bold"
        navigate={~p"/companies/#{@current_company}/salary_types/#{@obj.id}/edit"}
      >
        <%= @obj.name %>
      </.link> &#8226;
      <%= @obj.db_ac_name %> &#8226;
      <%= @obj.cr_ac_name %>
    </div>
    """
  end
end
