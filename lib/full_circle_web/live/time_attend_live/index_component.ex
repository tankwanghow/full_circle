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
      class={"#{@ex_class} flex flex-row text-center tracking-tighter bg-gray-200 hover:bg-gray-400"}
    >
      <div class="w-[30%] border-b border-gray-400">
        {@obj.employee_name}
      </div>
      <div class="w-[15%] border-b border-gray-400">
        <.link
          class="text-blue-600 hover:font-bold"
          phx-value-id={@obj.id}
          phx-click={:edit_timeattend}
        >
          {Timex.to_datetime(@obj.punch_time, @company.timezone)
          |> Timex.format!("%a, %Y-%m-%d %H:%M", :strftime)}
        </.link>
      </div>
      <div class="w-[10%] border-b text-center border-gray-400">
        {@obj.flag}
      </div>
      <div class="w-[15%] border-b text-center border-gray-400">
        {@obj.input_medium}
      </div>
      <div class="w-[15%] border-b text-center border-gray-400">
        {@obj.email}
      </div>
      <div class="w-[15%] border-b text-center border-gray-400">
        {FullCircleWeb.Helpers.format_datetime(@obj.updated_at, @company)}
      </div>
    </div>
    """
  end
end
