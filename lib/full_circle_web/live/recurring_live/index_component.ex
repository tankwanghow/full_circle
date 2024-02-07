defmodule FullCircleWeb.RecurringLive.IndexComponent do
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
      class={"#{@ex_class} text-center bg-gray-200 border-gray-500 hover:bg-gray-300 border-b p-1"}
    >
      <.link
        class="text-blue-600 hover:font-bold"
        navigate={~p"/companies/#{@current_company}/recurrings/#{@obj.id}/edit"}
      >
        <%= @obj.recur_no %>
      </.link>
      &#8226; <%= @obj.recur_date |> FullCircleWeb.Helpers.format_date() %> &#8226; <%= @obj.employee_name %> &#8226; <%= @obj.salary_type_name %> &#8226; <%= @obj.start_date
      |> FullCircleWeb.Helpers.format_date() %> &#8226; <%= @obj.status %>
    </div>
    """
  end
end
