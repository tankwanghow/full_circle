defmodule FullCircleWeb.LayerLive.FlockIndexComponent do
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
      <div class="w-[10%] shrink-0 min-w-0 truncate px-1">
        {@obj.dob |> FullCircleWeb.Helpers.format_date()}
      </div>
      <div class="w-[14%] shrink-0 min-w-0 truncate px-1">
        <.link
          class="text-blue-600 hover:font-bold"
          tabindex="-1"
          navigate={~p"/companies/#{@company}/flocks/#{@obj.id}/edit"}
        >
          {@obj.flock_no}
        </.link>
      </div>
      <div class="w-[10%] shrink-0 min-w-0 truncate px-1">
        <span class={muted_class()}>{@obj.breed}</span>
      </div>
      <div class="w-[10%] shrink-0 min-w-0 truncate px-1 text-right tabular-nums">
        {Number.Delimit.number_to_delimited(@obj.quantity, precision: 0)}
      </div>
      <div class="w-[31%] shrink-0 min-w-0 truncate px-1">
        {@obj.houses}
      </div>
      <div class="w-[25%] shrink-0 min-w-0 truncate px-1">
        <span class={muted_class()}>{@obj.note}</span>
      </div>
    </div>
    """
  end
end
