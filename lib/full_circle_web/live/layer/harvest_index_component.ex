defmodule FullCircleWeb.LayerLive.HarvestIndexComponent do
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
      <div class="w-[15%] shrink-0 min-w-0 truncate px-1">
        {@obj.har_date |> FullCircleWeb.Helpers.format_date()}
      </div>
      <div class="w-[15%] shrink-0 min-w-0 truncate px-1">
        <.link
          class="text-blue-600 hover:font-bold"
          tabindex="-1"
          navigate={~p"/companies/#{@company}/harvests/#{@obj.id}/edit"}
        >
          {@obj.harvest_no}
        </.link>
      </div>
      <div class="w-[30%] shrink-0 min-w-0 truncate px-1">
        <span class={muted_class()}>{@obj.employee_name}</span>
      </div>
      <div class="w-[40%] shrink-0 min-w-0 truncate px-1">
        {@obj.houses}
      </div>
    </div>
    """
  end
end
