defmodule FullCircleWeb.LayerLive.FlockIndexComponent do
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
    <div id={@id} class={"#{@ex_class}flex text-center"}>
      <div class="w-[15%] border-b border-gray-400 py-1">
        <%= @obj.dob |> FullCircleWeb.Helpers.format_date() %>
      </div>
      <div class="w-[15%] border-b border-gray-400 py-1">
        <.link
          class="text-blue-600 hover:font-bold"
          tabindex="-1"
          navigate={~p"/companies/#{@company}/flocks/#{@obj.id}/edit"}
        >
          <%= @obj.flock_no %>
        </.link>
      </div>
      <div class="w-[15%] border-b text-center border-gray-400 py-1 overflow-clip">
        <span class="font-light"><%= @obj.breed %></span>
      </div>
      <div class="w-[15%] border-b border-gray-400 py-1">
        <%= Number.Delimit.number_to_delimited(@obj.quantity, precision: 0) %>
      </div>
      <div class="w-[15%] border-b border-gray-400 py-1">
        <%= Number.Delimit.number_to_delimited(@obj.quantity, precision: 0) %>
      </div>
      <div class="w-[25%] border-b text-center border-gray-400 py-1 overflow-clip">
        <span class="font-light"><%= @obj.note %></span>
      </div>
    </div>
    """
  end
end
