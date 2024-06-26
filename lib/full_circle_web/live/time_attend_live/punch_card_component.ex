defmodule FullCircleWeb.TimeAttendLive.PunchCardComponent do
  use FullCircleWeb, :live_component

  @impl true
  def mount(socket) do
    {:ok, socket}
  end

  @impl true
  def update(assigns, socket) do
    yw = FullCircleWeb.Helpers.work_week(assigns.obj.dd)

    tis =
      if(assigns.obj.time_list != []) do
        assigns.obj.time_list
        |> Enum.map(fn [t, i, s, f] ->
          {Timex.format!(
             Timex.to_datetime(t, assigns.company.timezone),
             "%H:%M",
             :strftime
           ), i, s, f}
        end)
      else
        nil
      end

    {:ok, socket |> assign(assigns) |> assign(yw: yw) |> assign(tis: tis)}
  end

  def is_sunday(dd) do
    dd |> Timex.weekday() == 7
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id={@id}
      class={[
        "flex flex-row text-center",
        if(@obj.id == @shake_obj.id, do: "shake", else: ""),
        if(@obj.dd |> is_sunday(),
          do: "bg-rose-200 hover:bg-rose-300",
          else: "bg-gray-200 hover:bg-gray-300"
        )
      ]}
    >
      <div class="w-[20%] border-b border-gray-400">
        <%= FullCircleWeb.Helpers.format_date(@obj.dd) %>
        <span :if={!is_nil(@obj.sholi_list)} class="group relative w-max">
          <span class="text-rose-500"><%= @obj.sholi_list %></span>
          <span class="pointer-events-none absolute -top-2 left-2 w-max opacity-0 transition-opacity group-hover:opacity-100 bg-white rounded-xl px-2 py-1 text-sm">
            <%= @obj.holi_list %>
          </span>
        </span>
      </div>
      <div class="w-[15%] border-b border-gray-400">
        <%= @yw %>, <%= @obj.dd |> Timex.weekday() |> Timex.day_shortname() %>
      </div>
      <div class="w-[12%] border-b border-gray-400">
        <%= @obj.shift %>
      </div>
      <div class="w-[32%] border-b border-gray-400">
        <.live_component
          module={FullCircleWeb.TimeAttendLive.PunchTimeComponent}
          id={@id}
          comp_id={@id}
          obj={@tis}
          company={@company}
        />
      </div>
      <div class="w-[7%] border-b text-center border-gray-400">
        <%= Number.Delimit.number_to_delimited(@obj.wh) %>
      </div>
      <div class="w-[7%] border-b text-center border-gray-400">
        <%= Number.Delimit.number_to_delimited(@obj.nh) %>
      </div>
      <div class="w-[7%] border-b text-center border-gray-400">
        <%= Number.Delimit.number_to_delimited(@obj.ot) %>
      </div>
    </div>
    """
  end
end
