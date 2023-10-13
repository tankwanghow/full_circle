defmodule FullCircleWeb.EmployeeLive.IndexComponent do
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
      class={"#{@ex_class} text-center bg-gray-200 border-gray-500 border-b p-1"}
    >
    <div class="float-left ml-5">
      <input
        :if={@obj.checked}
        id={"checkbox_#{@obj.id}"}
        name={"checkbox[#{@obj.id}]"}
        type="checkbox"
        phx-click="check_click"
        phx-value-object-id={@obj.id}
        checked
      />
      <input
        :if={!@obj.checked}
        id={"checkbox_#{@obj.id}"}
        name={"checkbox[#{@obj.id}]"}
        type="checkbox"
        phx-click="check_click"
        phx-value-object-id={@obj.id}
      />
      </div>
      <.link
        class="text-blue-600 hover:font-bold"
        tabindex="-1"
        navigate={~p"/companies/#{@current_company}/employees/#{@obj.id}/edit"}
      >
        <%= @obj.name %>
      </.link>
      &#8226; <%= @obj.id_no %> &#8226; <%= @obj.nationality %> &#8226; <%= @obj.status %>
      <.link
        tabindex="-1"
        navigate={~p"/companies/#{@current_company}/employees/#{@obj.id}/copy"}
        class="text-xs hover:bg-orange-400 bg-orange-200 py-1 px-2 rounded-full border-orange-400 border"
      >
        <%= gettext("Copy") %>
      </.link>
    </div>
    """
  end
end
