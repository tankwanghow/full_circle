defmodule FullCircleWeb.TimeAttendLive.PunchIndexComponent do
  use FullCircleWeb, :live_component

  require Integer

  @impl true
  def mount(socket) do
    {:ok, socket}
  end

  @impl true
  def update(assigns, socket) do
    yw = FullCircleWeb.Helpers.work_week(assigns.obj.dd)
    tis = FullCircleWeb.Helpers.make_timeattend_list(assigns.obj.time_list, assigns.company)
    {:ok, socket |> assign(assigns) |> assign(yw: yw) |> assign(tis: tis)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class={"#{@ex_class} flex flex-row text-center bg-gray-200 hover:bg-gray-300"}>
      <div class="w-[25%] border-b border-gray-400">
        {@obj.name}
      </div>
      <div class="w-[15%] border-b border-gray-400">
        {FullCircleWeb.Helpers.format_date(@obj.dd)}
        <span :if={!is_nil(@obj.sholi_list)} class="group relative w-max">
          <span class="text-rose-500">{@obj.sholi_list}</span>
          <span class="pointer-events-none absolute -top-2 left-2 w-max opacity-0 transition-opacity group-hover:opacity-100 bg-white rounded-xl px-2 py-1 text-sm">
            {@obj.holi_list}
          </span>
        </span>
      </div>
      <div class="w-[10%] border-b border-gray-400">
        {@yw}, {@obj.dd |> Timex.weekday() |> Timex.day_shortname()}
      </div>
      <div class="w-[50%] border-b border-gray-400">
        <.live_component
          module={FullCircleWeb.TimeAttendLive.PunchTimeComponent}
          id={@id}
          comp_id={@id}
          obj={@obj}
          tis={@tis}
          company={@company}
          user={@user}
        />
      </div>
    </div>
    """
  end
end
