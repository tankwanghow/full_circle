defmodule FullCircleWeb.TimeAttendLive.PunchTimeComponent do
  use FullCircleWeb, :live_component

  alias FullCircle.HR
  alias FullCircle.HR.ShiftInstance

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(bg_color: "bg-transparent")
     |> assign(payslip_locked?: false)
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

    send(
      self(),
      {:updated_punch, socket.assigns.obj.id, socket.assigns.tis, socket.assigns.wh,
       socket.assigns.nh, socket.assigns.ot}
    )

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
    |> assign(bg_color: "bg-transparent")
    |> assign(
      tis:
        List.replace_at(
          socket.assigns.tis,
          Enum.find_index(socket.assigns.tis, fn t -> elem(t, 1) == taid end),
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
        |> assign(bg_color: "bg-transparent")
        |> assign(
          tis:
            List.replace_at(
              socket.assigns.tis,
              Enum.find_index(socket.assigns.tis, fn t -> elem(t, 1) == taid end),
              {punch_time, obj.id, obj.status, obj.flag, punch_time_local}
            )
        )
        |> update_working_hours

      {:error, _cs} ->
        socket |> assign(bg_color: "bg-red-300")

      :not_authorise ->
        socket |> assign(bg_color: "bg-red-300")
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
        idx = Enum.find_index(socket.assigns.tis, fn t -> elem(t, 1) == taid end)
        old = Enum.at(socket.assigns.tis, idx)

        socket
        |> assign(bg_color: "bg-transparent")
        |> assign(
          tis:
            List.replace_at(
              socket.assigns.tis,
              idx,
              {punch_time, obj.id, obj.status, obj.flag, punch_time_local, photo_from(old)}
            )
        )
        |> update_working_hours

      {:error, _cs} ->
        socket |> assign(bg_color: "bg-red-300")

      :not_authorise ->
        socket |> assign(bg_color: "bg-red-300")
    end
  end

  defp update_working_hours(socket) do
    tis = Enum.map(socket.assigns.tis, &pad_tis/1)

    tl =
      Enum.map(tis, fn {_ti, id, st, fl, dt, _p} -> [dt, id, st, fl] end)

    filled = tl |> Enum.reject(fn [dt | _] -> is_nil(dt) end) |> Enum.map(fn [dt | _] -> dt end)

    ordered? =
      filled
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.all?(fn [a, b] -> DateTime.compare(a, b) == :lt end)

    span =
      case filled do
        [] -> 0.0
        [_] -> 0.0
        list -> DateTime.diff(List.last(list), hd(list)) / 3600
      end

    # The same rule the query uses, so the component cannot disagree with the
    # row it is rendering. Out-of-order punches stay a red-row signal of their
    # own - they are not an anomaly the query knows about.
    anomaly = ShiftInstance.anomaly(length(filled), span, max_hour(socket))

    # Blank, not a partial sum. HR.wh/1 chunks in twos and rescues the leftover
    # to 0.0, so an odd day would otherwise show the hours of its complete pairs
    # as if that were the day's total.
    wh = if is_nil(anomaly), do: HR.wh(tl), else: nil

    tl_ok? = is_nil(anomaly) and ordered?

    socket =
      if !tl_ok? do
        socket |> assign(bg_color: "bg-red-300")
      else
        socket |> assign(bg_color: "bg-transparent")
      end

    socket
    |> assign(wh: wh)
    |> assign(nh: wh && HR.nh(wh, socket.assigns.obj.work_hours_per_day))
    |> assign(ot: wh && HR.ot(wh, socket.assigns.obj.work_hours_per_day))
  end

  # The row's shift, when Task 7 has put it there; the seeded General tolerance
  # otherwise, which is what every existing row resolves to anyway.
  defp max_hour(socket) do
    case socket.assigns.obj do
      %{work_shift: %FullCircle.HR.WorkShift{max_hour: m}} -> m
      _ -> Decimal.new("12")
    end
  end

  # A time-only input has to be placed on one of two candidate dates: the
  # instance's anchor day, or the day after it. Exactly one of them puts the
  # time inside the instance's half-open window.
  def slot_date(pt, anchor, %FullCircle.HR.WorkShift{} = ws) do
    {:ok, time} = Time.from_iso8601(pt <> ":00")

    if Time.compare(time, FullCircle.HR.WorkShift.cutover_time(ws)) in [:gt, :eq],
      do: anchor,
      else: Date.add(anchor, 1)
  end

  defp add_date_to(pt, socket) do
    %{company: com, obj: obj} = socket.assigns
    {:ok, time} = Time.from_iso8601(pt <> ":00")

    date =
      case Map.get(obj, :work_shift) do
        %FullCircle.HR.WorkShift{} = ws ->
          slot_date(pt, Map.get(obj, :work_shift_date) || Timex.to_date(obj.dd), ws)

        # Before Task 7 lands the shift on the row, a row is still a calendar
        # day and the old behaviour is the correct one.
        _ ->
          Timex.to_date(obj.dd)
      end

    DateTime.new!(date, time, com.timezone)
  end

  defp pad_tis({t, i, s, f, d}), do: {t, i, s, f, d, ""}
  defp pad_tis({t, i, s, f, d, p}), do: {t, i, s, f, d, p}

  defp photo_from(t) when is_tuple(t) and tuple_size(t) >= 6, do: elem(t, 5)
  defp photo_from(_), do: ""

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-nowrap gap-1">
      <div class="w-[70%] flex flex-wrap gap-1">
        <%= if !is_nil(@tis) do %>
          <%= for o <- @tis do %>
            <% {time, id, status, flag, datetime, photo} = pad_tis(o) %>
            <.form
              for={}
              autocomplete="off"
              phx-change="punch_time_changed"
              phx-target={@myself}
              class="w-[16.666%]"
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
                readonly={@payslip_locked?}
                title={@payslip_locked? && gettext("Locked: a pay slip exists for this month")}
                class={[
                  "rounded h-6 w-full text-center text-black",
                  (@payslip_locked? && "bg-gray-300 cursor-not-allowed") || @bg_color
                ]}
                phx-debounce="blur"
                id={id}
              />
              <.link
                :if={photo != "" and !String.starts_with?(id, "_new_")}
                href={~p"/companies/#{@company.id}/TimeAttend/#{id}/photo"}
                target="_blank"
                class="punch-photo text-center text-xs"
              >
                <img
                  src={~p"/companies/#{@company.id}/TimeAttend/#{id}/photo"}
                  loading="lazy"
                  alt={gettext("Punch photo")}
                  class="mt-0.5 w-full h-12 object-cover rounded border border-gray-400 dark:border-gray-600"
                />
              </.link>
            </.form>
          <% end %>
        <% end %>
      </div>
      <div class="worked-hours w-[10%] text-center">
        {Number.Delimit.number_to_delimited(@wh)}
      </div>
      <div class="normal-hours w-[10%] text-center">
        {Number.Delimit.number_to_delimited(@nh)}
      </div>
      <div class="ot-hours w-[10%] text-center">
        {Number.Delimit.number_to_delimited(@ot)}
      </div>
    </div>
    """
  end
end
