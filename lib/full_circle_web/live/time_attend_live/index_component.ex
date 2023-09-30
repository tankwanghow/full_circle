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
        <%= @obj.name %>
      </div>
      <div class="w-[15%] border-b border-gray-400 py-1">
        <%= @obj.id_no %>
      </div>
      <div class="w-[22.5%] border-b border-gray-400 py-1">
        <.link
          class="text-blue-600 hover:font-bold"
          navigate={~p"/companies/#{@company}/TimeAttend/#{@obj.in_id}/edit"}
        >
          <%= FullCircleWeb.Helpers.format_datetime(@obj.in_time, @company) %>
        </.link>
        <span class="text-gray-500"><%= @obj.in_medium %></span>
      </div>
      <div class="w-[22.5%] border-b border-gray-400 py-1">
        <.link
          :if={@obj.out_id}
          class="text-blue-600 hover:font-bold"
          navigate={~p"/companies/#{@company}/TimeAttend/#{@obj.out_id}/edit"}
        >
          <%= FullCircleWeb.Helpers.format_datetime(@obj.out_time, @company) %>
        </.link>
        <span class="text-gray-500"><%= @obj.out_medium %></span>
      </div>
      <div class="w-[10%] border-b text-center border-gray-400 py-1 overflow-clip">
        <%= Number.Delimit.number_to_delimited(@obj.wh / 60) %>
      </div>
    </div>
    """
  end
end
