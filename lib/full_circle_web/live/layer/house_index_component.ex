defmodule FullCircleWeb.LayerLive.HouseIndexComponent do
  use FullCircleWeb, :live_component

  import FullCircleWeb.ListComponents

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
      class={[row_class(@ex_class), line_class("gap-0")]}
    >
      <div class="w-[14%] shrink-0 min-w-0 truncate px-1">
        <.link
          class="text-blue-600 hover:font-bold"
          tabindex="-1"
          navigate={~p"/companies/#{@company}/houses/#{@obj.id}/edit"}
        >
          {@obj.house_no}
        </.link>
      </div>
      <div class="w-[14%] shrink-0 min-w-0 truncate px-1">
        {@obj.capacity}
      </div>
      <div class="w-[15%] shrink-0 min-w-0 truncate px-1">
        {@obj.flock_no}
      </div>
      <div class="w-[15%] shrink-0 min-w-0 truncate px-1">
        {@obj.qty}
      </div>
      <div class="w-[14%] shrink-0 min-w-0 truncate px-1">
        {@obj.filling_wages}
      </div>
      <div class="w-[14%] shrink-0 min-w-0 truncate px-1">
        {@obj.feeding_wages}
      </div>
      <div class="w-[14%] shrink-0 min-w-0 truncate px-1">
        {@obj.status}
      </div>
    </div>
    """
  end
end
