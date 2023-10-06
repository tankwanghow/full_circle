defmodule FullCircleWeb.TimeAttendLive.IndexComponent do
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
      class={"#{@ex_class} max-h-8 flex flex-row text-center tracking-tighter bg-gray-200 hover:bg-gray-400"}
    >
      <div class="w-[30%] border-b border-gray-400 py-1">
        <%= @obj.employee_name %>
      </div>
      <div class="w-[10%] border-b border-gray-400 py-1">
        <%= @obj.shift_id %>
      </div>
      <div class="w-[15%] border-b border-gray-400 py-1">
        <.link
          class="text-blue-600 hover:font-bold"
          navigate={~p"/companies/#{@company}/TimeAttend/#{@obj.id}/edit"}
        >
          <%= @obj.punch_time |> Timex.weekday() |> Timex.day_shortname() %>, <%= FullCircleWeb.Helpers.format_datetime(
            @obj.punch_time,
            @company
          ) %>
        </.link>
      </div>
      <div class="w-[5%] border-b text-center border-gray-400 py-1 overflow-clip">
        <%= @obj.flag %>
      </div>
      <div class="w-[10%] border-b text-center border-gray-400 py-1 overflow-clip">
        <%= @obj.input_medium %>
      </div>
      <div class="w-[15%] border-b text-center border-gray-400 py-1 overflow-clip">
        <%= @obj.email %>
      </div>
      <div class="w-[15%] border-b text-center border-gray-400 py-1 overflow-clip">
        <%= FullCircleWeb.Helpers.format_datetime(@obj.updated_at, @company) %>
      </div>
    </div>
    """
  end
end
