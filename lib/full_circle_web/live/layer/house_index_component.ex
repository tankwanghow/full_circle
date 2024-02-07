defmodule FullCircleWeb.LayerLive.HouseIndexComponent do
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
      class={"#{@ex_class}flex p-1 text-center bg-gray-200 border-gray-500 hover:bg-gray-300 border-b"}
    >
      <div class="w-[14%]">
        <.link
          class="text-blue-600 hover:font-bold"
          tabindex="-1"
          navigate={~p"/companies/#{@company}/houses/#{@obj.id}/edit"}
        >
          <%= @obj.house_no %>
        </.link>
      </div>
      <div class="w-[14%]">
        <%= @obj.capacity %>
      </div>
      <div class="w-[15%]">
        <%= @obj.flock_no %>
      </div>
      <div class="w-[15%]">
        <%= @obj.qty %>
      </div>
      <div class="w-[14%]">
        <%= @obj.filling_wages %>
      </div>
      <div class="w-[14%]">
        <%= @obj.feeding_wages %>
      </div>
      <div class="w-[14%]">
        <%= @obj.status %>
      </div>
    </div>
    """
  end
end
