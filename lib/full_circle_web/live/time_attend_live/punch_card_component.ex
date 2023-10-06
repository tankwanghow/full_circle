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
      if(!is_nil(assigns.obj.time_list)) do
        tls =
          assigns.obj.time_list
          |> String.split("|")
          |> Enum.map(fn x -> if(x != "", do: Timex.parse!(x, "{RFC3339}"), else: "") end)
          |> Enum.map(fn x ->
            if(x != "",
              do:
                Timex.format!(
                  Timex.to_datetime(x, assigns.company.timezone),
                  "%H:%M",
                  :strftime
                ),
              else: ""
            )
          end)

        ids = assigns.obj.id_list |> String.split("|")

        Enum.zip(tls, ids)
        |> Enum.zip_with(String.split(assigns.obj.st_list, "|"), fn {x, y}, z -> {x, y, z} end)
      else
        nil
      end

    {:ok, socket |> assign(assigns) |> assign(yw: yw) |> assign(tis: tis) }
  end

  defp normal_work_hour(nh, wh) do
    cond do
      wh == nh -> nh
      wh > nh -> nh
      wh < nh -> wh
    end
  end



  @impl true
  def render(assigns) do
    ~H"""
    <div
      id={@id}
      class={[
        "#max-h-8 flex flex-row text-center tracking-tightr",
        if(@obj.dd |> Timex.weekday() == 7, do: "bg-rose-200", else: "bg-gray-200")
      ]}
    >
      <div class="w-[15%] border-b border-gray-400 py-1">
        <%= FullCircleWeb.Helpers.format_date(@obj.dd) %>
      </div>
      <div class="w-[15%] border-b border-gray-400 py-1">
        <%= @yw %>, <%= @obj.dd |> Timex.weekday() |> Timex.day_shortname() %>
      </div>
      <div class="w-[10%] border-b border-gray-400 py-1">
        <%= @obj.shift %>
      </div>
      <div class="w-[36%] border-b border-gray-400 py-1">
        <.live_component
          module={FullCircleWeb.TimeAttendLive.PunchTimeComponent}
          id={FullCircle.Helpers.gen_temp_id(6)}
          obj={@tis}
          company={@company}
        />
      </div>
      <div class="w-[8%] border-b text-center border-gray-400 py-1 overflow-clip">
        <%= Number.Delimit.number_to_delimited(@obj.wh) %>
      </div>
      <div class="w-[8%] border-b text-center border-gray-400 py-1 overflow-clip">
        <%= Number.Delimit.number_to_delimited(@obj.nh) %>
      </div>
      <div class="w-[8%] border-b text-center border-gray-400 py-1 overflow-clip">
        <%= Number.Delimit.number_to_delimited(@obj.ot) %>
      </div>
    </div>
    """
  end
end
