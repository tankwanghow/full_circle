defmodule FullCircleWeb.TimeAttendLive.PunchTimeComponent do
  use FullCircleWeb, :live_component

  alias FullCircle.HR

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(border_color: "bg-blue-200")
     |> assign(wh: 0)
     |> assign(nh: 0)
     |> assign(ot: 0)}
  end

  @impl true
  def update(assigns, socket) do
    {:ok, socket |> assign(assigns) |> update_working_hours}
  end

  @impl true
  def handle_event(
        "punch_time_changed",
        %{"_target" => ["punch_time"], "_unused_punch_time" => ""},
        socket
      ) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("punch_time_changed", params, socket) do
    socket =
      cond do
        String.starts_with?(params["taid"], "_new_") and params["punch_time"] != "" ->
          new_time_attendence(params, socket)

        !String.starts_with?(params["taid"], "_new_") and params["punch_time"] == "" ->
          delete_time_attendence(params, socket)

        !String.starts_with?(params["taid"], "_new_") and params["punch_time"] != "" ->
          update_time_attendence(params, socket)

        true ->
          socket
      end

    send(self(), {:updated_punch, socket.assigns.obj.id, socket.assigns.tis, socket.assigns.wh, socket.assigns.nh, socket.assigns.ot})

    {:noreply, socket}
  end

  defp delete_time_attendence(
         %{
           "flag" => flag,
           "status" => status,
           "taid" => taid
         },
         socket
       ) do
    HR.delete_time_attendence_by_id(taid, socket.assigns.company, socket.assigns.user)

    socket
    |> assign(border_color: "bg-green-200")
    |> assign(
      tis:
        List.replace_at(
          socket.assigns.tis,
          Enum.find_index(socket.assigns.tis, fn {_, id, _, _, _} -> id == taid end),
          {nil, "_new_#{FullCircle.Helpers.gen_temp_id(31)}", status, flag, nil}
        )
    )
    |> update_working_hours
  end

  defp new_time_attendence(
         %{
           "employee_id" => emp_id,
           "flag" => flag,
           "punch_time" => punch_time,
           "status" => status,
           "taid" => taid
         },
         socket
       ) do
    punch_time_local = add_date_to(punch_time, socket)

    case(
      HR.create_time_attendence_by_entry(
        %{
          input_medium: "UserEntry",
          employee_id: emp_id,
          flag: flag,
          punch_time_local: punch_time_local,
          status: status,
          company_id: socket.assigns.company.id,
          user_id: socket.assigns.user.id,
          employee_name: socket.assigns.obj.name
        },
        socket.assigns.company,
        socket.assigns.user
      )
    ) do
      {:ok, obj} ->
        socket
        |> assign(border_color: "bg-green-200")
        |> assign(
          tis:
            List.replace_at(
              socket.assigns.tis,
              Enum.find_index(socket.assigns.tis, fn {_, id, _, _, _} -> id == taid end),
              {punch_time, obj.id, obj.status, obj.flag, punch_time_local}
            )
        )
        |> update_working_hours

      {:error, _cs} ->
        socket |> assign(border_color: "bg-rose-200")

      :not_authorise ->
        socket |> assign(border_color: "bg-rose-200")
    end
  end

  defp update_time_attendence(params, socket) do
    %{
      "employee_id" => emp_id,
      "flag" => flag,
      "punch_time" => punch_time,
      "status" => status,
      "taid" => taid
    } = params

    punch_time_local = add_date_to(punch_time, socket)

    case(
      HR.update_time_attendence(
        %FullCircle.HR.TimeAttend{
          input_medium: "UserEntry",
          employee_id: emp_id,
          flag: flag,
          punch_time_local: punch_time_local,
          status: status,
          id: taid,
          company_id: socket.assigns.company.id,
          user_id: socket.assigns.user.id,
          employee_name: socket.assigns.obj.name
        },
        %{
          input_medium: "UserEntry",
          punch_time_local: punch_time_local
        },
        socket.assigns.company,
        socket.assigns.user
      )
    ) do
      {:ok, obj} ->
        socket
        |> assign(border_color: "bg-green-200")
        |> assign(
          tis:
            List.replace_at(
              socket.assigns.tis,
              Enum.find_index(socket.assigns.tis, fn {_, id, _, _, _} -> id == taid end),
              {punch_time, obj.id, obj.status, obj.flag, punch_time_local}
            )
        )
        |> update_working_hours

      {:error, _cs} ->
        socket |> assign(border_color: "bg-rose-200")

      :not_authorise ->
        socket |> assign(border_color: "bg-rose-200")
    end
  end

  defp update_working_hours(socket) do
    [
      {_ti1, id1, st1, fl1, dt1},
      {_ti2, id2, st2, fl2, dt2},
      {_ti3, id3, st3, fl3, dt3},
      {_ti4, id4, st4, fl4, dt4},
      {_ti5, id5, st5, fl5, dt5},
      {_ti6, id6, st6, fl6, dt6}
    ] = socket.assigns.tis

    wh =
      HR.wh([
        [dt1, id1, st1, fl1],
        [dt2, id2, st2, fl2],
        [dt3, id3, st3, fl3],
        [dt4, id4, st4, fl4],
        [dt5, id5, st5, fl5],
        [dt6, id6, st6, fl6]
      ])

    socket
    |> assign(wh: wh)
    |> assign(nh: HR.nh(wh, socket.assigns.obj.work_hours_per_day))
    |> assign(ot: HR.ot(wh, socket.assigns.obj.work_hours_per_day))
  end

  defp add_date_to(pt, socket) do
    "#{Timex.format!(socket.assigns.obj.dd, "%Y-%m-%d", :strftime)}T#{pt}"
    |> Timex.parse!("{RFC3339}")
    |> Timex.to_datetime(socket.assigns.company.timezone)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-nowrap">
      <%= if !is_nil(@tis) do %>
        <%= for o <- @tis do %>
          <% {time, id, status, flag, datetime} = o %>
          <.form
            for={}
            autocomplete="off"
            phx-change="punch_time_changed"
            phx-target={@myself}
            class="w-[11.666%]"
          >
            <input name="flag" type="hidden" value={flag} />
            <input name="status" type="hidden" value={status} />
            <input name="employee_id" type="hidden" value={@obj.employee_id} />
            <input name="datetime" type="hidden" value={datetime} />
            <input name="taid" type="hidden" value={id} />
            <input
              name="punch_time"
              type="time"
              value={time}
              class={"rounded h-6 #{@border_color} w-full text-center"}
              phx-debounce="blur"
              id={id}
            />
          </.form>
        <% end %>
      <% end %>
      <div class="worked-hours w-[10%] border-b text-center border-gray-400">
        <%= Number.Delimit.number_to_delimited(@wh) %>
      </div>
      <div class="normal-hours w-[10%] border-b text-center border-gray-400">
        <%= Number.Delimit.number_to_delimited(@nh) %>
      </div>
      <div class="ot-hours w-[10%] border-b text-center border-gray-400">
        <%= Number.Delimit.number_to_delimited(@ot) %>
      </div>
    </div>
    """
  end
end
