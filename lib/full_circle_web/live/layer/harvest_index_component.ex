defmodule FullCircleWeb.LayerLive.HarvestIndexComponent do
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
      class={"#{@ex_class}flex text-center border-b border-gray-500 hover:bg-gray-300 bg-gray-200"}
    >
      <div class="w-[15%] py-1">
        {@obj.har_date |> FullCircleWeb.Helpers.format_date()}
      </div>
      <div class="w-[15%] py-1">
        <.link
          class="text-blue-600 hover:font-bold"
          tabindex="-1"
          navigate={~p"/companies/#{@company}/harvests/#{@obj.id}/edit"}
        >
          {@obj.harvest_no}
        </.link>
      </div>
      <div class="w-[30%] py-1 overflow-clip">
        <span class="font-light">{@obj.employee_name}</span>
      </div>
      <div class="w-[40%] py-1">
        {@obj.houses}
      </div>
    </div>
    """
  end
end
