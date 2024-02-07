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
    <div
      id={@id}
      class={"#{@ex_class}flex text-center border-b border-gray-400 hover:bg-gray-300 bg-gray-200 "}
    >
      <div class="w-[10%] py-1">
        <%= @obj.dob |> FullCircleWeb.Helpers.format_date() %>
      </div>
      <div class="w-[14%] py-1">
        <.link
          class="text-blue-600 hover:font-bold"
          tabindex="-1"
          navigate={~p"/companies/#{@company}/flocks/#{@obj.id}/edit"}
        >
          <%= @obj.flock_no %>
        </.link>
      </div>
      <div class="w-[10%] py-1 overflow-clip">
        <span class="font-light"><%= @obj.breed %></span>
      </div>
      <div class="w-[10%] border-b py-1">
        <%= Number.Delimit.number_to_delimited(@obj.quantity, precision: 0) %>
      </div>
      <div class="w-[31%] py-1">
        <%= @obj.houses %>
      </div>
      <div class="w-[25%] py-1 overflow-clip">
        <span class="font-light"><%= @obj.note %></span>
      </div>
    </div>
    """
  end
end
