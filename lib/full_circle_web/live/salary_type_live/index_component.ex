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
      class={"#{@ex_class} text-center bg-gray-200 border-gray-500 border-b py-1"}
    >
      <%= if !FullCircle.HR.is_default_salary_type?(@obj) do %>
        <.link
          class="hover:font-bold text-blue-600"
          navigate={~p"/companies/#{@current_company.id}/salary_types/#{@obj.id}/edit"}
        >
          <%= @obj.name %>
        </.link>
      <% else %>
        <%= if @current_role == "admin" do %>
          <.link
            class="hover:font-bold text-purple-600"
            navigate={~p"/companies/#{@current_company.id}/salary_types/#{@obj.id}/edit"}
          >
            <%= @obj.name %>
          </.link>
        <% else %>
          <span class="font-bold text-rose-600">
            <%= @obj.name %>
          </span>
        <% end %>
      <% end %>
      &#8226; <%= @obj.type %> &#8226; <%= @obj.db_ac_name %> &#8226; <%= @obj.cr_ac_name %>
    </div>
    """
  end
end
