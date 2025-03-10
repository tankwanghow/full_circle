defmodule FullCircleWeb.TimeAttendLive.PunchCard do
  use FullCircleWeb, :live_view

  alias FullCircle.{HR, PaySlipOp}
  alias FullCircleWeb.TimeAttendLive.{PunchCardComponent, AdvanceComponent, SalaryNoteComponent}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto w-8/12">
      <p class="w-full text-3xl text-center font-medium">{@page_title}</p>

      <.form
        for={%{}}
        id="search-form"
        phx-submit="search"
        autocomplete="off"
        class="mx-auto w-11/12 mb-2"
      >
        <div class=" flex flex-row gap-1 justify-center">
          <div class="w-[30%]">
            <.input
              id="search_employee_name"
              name="search[employee_name]"
              type="search"
              value={@search.employee_name}
              label={gettext("Employee")}
              phx-hook="tributeAutoComplete"
              url={"/list/companies/#{@current_company.id}/#{@current_user.id}/autocomplete?schema=employee&name="}
            />
          </div>
          <div class="w-[9%]">
            <.input
              min="1"
              max="12"
              name="search[month]"
              type="number"
              value={@search.month}
              id="search_month"
              label={gettext("Month")}
            />
          </div>
          <div class="w-[9%]">
            <.input
              min="2000"
              max="2099"
              name="search[year]"
              type="number"
              value={@search.year}
              id="search_year"
              label={gettext("Year")}
            />
          </div>
          <.button class="w-[5%] mt-5 h-10 grow-0 shrink-0">🔍</.button>
          <a onclick="history.back();" class="w-[7%] h-10 mt-5 blue button">{gettext("Back")}</a>
        </div>
      </.form>
      <div class="text-center my-4">
        <.link
          :if={@search.employee_name != ""}
          navigate={"/companies/#{@current_company.id}/employees/#{@employee.id}/edit"}
          class="w-[14%] h-10 mt-5 blue button ml-2"
          id="new_timeattend"
        >
          {gettext("Edit Employee")}
        </.link>
        <.link
          :if={@search.employee_name != ""}
          phx-click={:new_salarynote}
          class="w-[9%] h-10 mt-5 blue button ml-2"
          id="new_salarynote"
        >
          {gettext("+ Note")}
        </.link>
        <.link
          :if={@search.employee_name != ""}
          phx-click={:new_advance}
          class="w-[9%] h-10 mt-5 blue button ml-2"
          id="new_advance"
        >
          {gettext("+ Advance")}
        </.link>
        <.link
          :if={is_nil(@pay_slip)}
          navigate={@new_pay_slip_url}
          class="w-[10%] h-10 mt-5 blue button ml-2"
          id="new_payslip"
        >
          {gettext("+ Pay")}
        </.link>
        <.link
          :if={!is_nil(@pay_slip)}
          navigate={"/companies/#{@current_company.id}/PaySlip/#{@pay_slip.id}/recal"}
          class="w-[11%] h-10 mt-5 blue button ml-2"
          id="recal_payslip"
        >
          {gettext("Recal Pay")}
        </.link>
      </div>

      <div :if={@employee} class="text-center">
        <span class="font-medium">{@employee.name}</span>
        from <span class="font-medium">{@employee.nationality}</span>
        with id <span class="font-medium">{@employee.id_no}</span>
        work in the company for
        <span class="font-medium">
          {(Timex.diff(Timex.today(), @employee.service_since, :days) / 365)
          |> Number.Delimit.number_to_delimited()}
        </span>
        years
        currently age
        <span class="font-medium">
          {(Timex.diff(Timex.today(), @employee.dob, :days) / 365)
          |> Number.Delimit.number_to_delimited()}
        </span>
        year old.
        <span :if={Enum.count(@leaves) == 0}>
          For the year, <span class="font-medium">{@employee.name}</span>
          has not taken any leaves yet.
        </span>
        <span :if={Enum.count(@leaves) > 0}>
          For the year, <span class="font-medium">{@employee.name}</span>
          has {Enum.map(@leaves, fn x -> "#{Decimal.to_string(x.amount)} #{x.name}" end)
          |> Enum.join(", ")}.
        </span>
      </div>

      <div class="flex flex-row justify-around gap-2 h-8 w-full mb-2 border-y border-purple-600 bg-purple-200">
        <span class="mt-1">
          Total:
          <span :if={@employee} id="total_worked_hours" class="font-bold text-orange-600">
            {@total_day_worked |> Number.Delimit.number_to_delimited()}
          </span>
        </span>
        <span class="mt-1">
          Overtime:
          <.link
            :if={@employee}
            id="total_ot_hours"
            class="text-blue-600 hover:font-bold"
            phx-value-qty={@ot_day_worked |> Number.Delimit.number_to_delimited()}
            phx-click={:new_salarynote_with_qty}
          >
            {@ot_day_worked |> Number.Delimit.number_to_delimited()}
          </.link>
        </span>
        <span class="mt-1">
          Normal:
          <.link
            :if={@employee}
            id="total_normal_hours"
            class="text-blue-600 hover:font-bold"
            phx-value-qty={@normal_pay_days |> Number.Delimit.number_to_delimited()}
            phx-click={:new_salarynote_with_qty}
          >
            {@normal_pay_days |> Number.Delimit.number_to_delimited()}
          </.link>
        </span>
        <span class="mt-1">
          Sunday:
          <.link
            :if={@employee}
            class="text-blue-600 hover:font-bold"
            phx-value-qty={@sunday_pay_days |> Number.Delimit.number_to_delimited()}
            phx-click={:new_salarynote_with_qty}
          >
            {@sunday_pay_days |> Number.Delimit.number_to_delimited()}
          </.link>
        </span>
        <span class="mt-1">
          <span class="group relative w-max">
            *Holiday:
            <span class="pointer-events-none absolute -top-7 left-2 w-max opacity-0 transition-opacity group-hover:opacity-100 bg-white rounded-xl px-2 py-1 text-sm">
              Uncertain rest day, Holiday might be wrong!!
            </span>
          </span>
          <.link
            :if={@employee}
            class="text-blue-600 hover:font-bold"
            phx-value-qty={@holiday_pay_days |> Number.Delimit.number_to_delimited()}
            phx-click={:new_salarynote_with_qty}
          >
            {@holiday_pay_days |> Number.Delimit.number_to_delimited()}
          </.link>
        </span>
      </div>

      <div
        id="timeAttendList"
        class="font-medium flex flex-row text-center tracking-tighter bg-blue-200"
      >
        <div class="w-[10%] border-b border-t border-blue-400 py-1">
          {gettext("Date")}
        </div>
        <div class="w-[10%] border-b border-t border-blue-400 py-1">
          {gettext("Note No")}
        </div>
        <div class="w-[10%] border-b border-t border-blue-400 py-1">
          {gettext("Pay Slip No")}
        </div>
        <div class="w-[20%] border-b border-t border-blue-400 py-1">
          {gettext("Salary Type")}
        </div>
        <div class="w-[26%] border-b border-t border-blue-400 py-1">
          {gettext("Descriptions")}
        </div>
        <div class="w-[8%] border-b border-t border-blue-400 py-1">
          {gettext("Quantity")}
        </div>
        <div class="w-[8%] border-b border-t border-blue-400 py-1">
          {gettext("Price")}
        </div>
        <div class="w-[8%] border-b border-t border-blue-400 py-1">
          {gettext("Amount")}
        </div>
      </div>
      <div id="notes_list" class="mb-5">
        <%= for obj <- @salary_notes do %>
          <.live_component
            module={SalaryNoteComponent}
            id={obj.id}
            obj={obj}
            company={@current_company}
            shake_obj={@shake_obj}
          />
        <% end %>

        <%= for obj <- @advances do %>
          <.live_component
            module={AdvanceComponent}
            id={obj.id}
            obj={obj}
            company={@current_company}
            shake_obj={@shake_obj}
          />
        <% end %>
      </div>

      <div class="font-medium flex flex-row text-center tracking-tighter bg-amber-200">
        <div class="w-[12%] border-b border-t border-amber-400 py-1">
          {gettext("Date")}
        </div>
        <div class="w-[12%] border-b border-t border-amber-400 py-1">
          {gettext("Holiday")}
        </div>
        <div class="w-[11%] border-b border-t border-amber-400 py-1">
          {gettext("Day")}
        </div>
        <div class="w-[65%] flex flex-row border-b border-t border-amber-400 py-1">
          <div class="w-[70%]">
            {gettext("Punches")}
          </div>
          <div class="w-[10%]">
            {gettext("HW")}
          </div>
          <div class="w-[10%]">
            {gettext("NH")}
          </div>
          <div class="w-[10%]">
            {gettext("OT")}
          </div>
        </div>
      </div>
      <div id="punches_list" class="mb-5">
        <%= for obj <- @punches do %>
          <.live_component
            module={PunchCardComponent}
            id={obj.id}
            obj={obj}
            user={@current_user}
            company={@current_company}
          />
        <% end %>
      </div>
    </div>
    <.modal
      :if={@live_action_sn in [:new, :edit]}
      id="salarynote-modal"
      show
      on_cancel={JS.push("modal_cancel")}
      max_w="max-w-4xl"
    >
      <.live_component
        module={FullCircleWeb.TimeAttendLive.SalaryNoteFormComponent}
        live_action={@live_action_sn}
        id={@obj.id || :new}
        obj={@obj}
        title={@title}
        action={@live_action_sn}
        current_company={@current_company}
        current_user={@current_user}
      />
    </.modal>
    <.modal
      :if={@live_action_adv in [:new, :edit]}
      id="advancenote-modal"
      show
      on_cancel={JS.push("modal_cancel")}
      max_w="max-w-3xl"
    >
      <.live_component
        module={FullCircleWeb.TimeAttendLive.AdvanceFormComponent}
        live_action={@live_action_adv}
        id={@obj.id || :new}
        obj={@obj}
        title={@title}
        action={@live_action_adv}
        current_company={@current_company}
        current_user={@current_user}
      />
    </.modal>
    """
  end

  @impl true
  def mount(params, _session, socket) do
    emp_name = params["search"]["employee_name"] || ""
    d = Timex.today() |> Timex.shift(months: -1)

    month = params["search"]["month"] || d.month
    year = params["search"]["year"] || d.year

    socket =
      socket
      |> assign(page_title: gettext("Punch Card"))
      |> assign(live_action_ta: :index)
      |> assign(live_action_sn: :index)
      |> assign(live_action_adv: :index)
      |> assign(shake_obj: %{id: ""})
      |> assign(search: %{employee_name: emp_name, month: month, year: year})
      |> filter_punches(month, year, emp_name)

    {:ok, socket}
  end

  @impl true
  def handle_event(
        "search",
        %{
          "search" => %{
            "employee_name" => name,
            "month" => month,
            "year" => year
          }
        },
        socket
      ) do
    qry = %{
      "search[employee_name]" => name,
      "search[month]" => month,
      "search[year]" => year
    }

    {:noreply,
     socket
     |> assign(search: %{employee_name: name, month: month, year: year})
     |> assign(shake_obj: %{id: ""})
     |> push_navigate(
       to: "/companies/#{socket.assigns.current_company.id}/PunchCard?#{URI.encode_query(qry)}"
     )}
  end

  def handle_event("new_salarynote", _, socket) do
    {:noreply,
     socket
     |> assign(live_action_sn: :new)
     |> assign(id: "new")
     |> assign(shake_obj: %{id: ""})
     |> assign(title: gettext("New Salary Note"))
     |> assign(
       obj: %FullCircle.HR.SalaryNote{
         note_no: "...new...",
         employee_name: socket.assigns.employee.name,
         employee_id: socket.assigns.employee.id,
         note_date:
           Timex.parse!(
             "#{socket.assigns.search.year}-#{socket.assigns.search.month}-01",
             "{YYYY}-{M}-{0D}"
           )
           |> Timex.end_of_month()
           |> Timex.to_date()
       }
     )}
  end

  def handle_event("new_advance", _, socket) do
    {:noreply,
     socket
     |> assign(live_action_adv: :new)
     |> assign(id: "new")
     |> assign(shake_obj: %{id: ""})
     |> assign(title: gettext("New Advance"))
     |> assign(
       obj: %FullCircle.HR.Advance{
         slip_no: "...new...",
         employee_name: socket.assigns.employee.name,
         employee_id: socket.assigns.employee.id,
         slip_date:
           Timex.parse!(
             "#{socket.assigns.search.year}-#{socket.assigns.search.month}-01",
             "{YYYY}-{M}-{0D}"
           )
           |> Timex.end_of_month()
           |> Timex.to_date()
       }
     )}
  end

  def handle_event("new_salarynote_with_qty", %{"qty" => qty}, socket) do
    {:noreply,
     socket
     |> assign(live_action_sn: :new)
     |> assign(id: "new")
     |> assign(title: gettext("New Salary Note"))
     |> assign(shake_obj: %{id: ""})
     |> assign(
       obj: %FullCircle.HR.SalaryNote{
         note_no: "...new...",
         employee_name: socket.assigns.employee.name,
         employee_id: socket.assigns.employee.id,
         quantity: qty,
         note_date:
           Timex.parse!(
             "#{socket.assigns.search.year}-#{socket.assigns.search.month}-01",
             "{YYYY}-{M}-{0D}"
           )
           |> Timex.end_of_month()
           |> Timex.to_date()
       }
     )}
  end

  def handle_event("edit_advance", params, socket) do
    obj =
      HR.get_advance!(
        params["id"],
        socket.assigns.current_company,
        socket.assigns.current_user
      )

    {:noreply,
     socket
     |> assign(live_action_adv: :edit)
     |> assign(id: params["id"])
     |> assign(shake_obj: %{id: ""})
     |> assign(title: gettext("Edit Advance") <> " " <> obj.slip_no)
     |> assign(obj: obj)}
  end

  def handle_event("edit_salarynote", params, socket) do
    obj =
      HR.get_salary_note!(
        params["id"],
        socket.assigns.current_company,
        socket.assigns.current_user
      )

    {:noreply,
     socket
     |> assign(live_action_sn: :edit)
     |> assign(id: params["id"])
     |> assign(shake_obj: %{id: ""})
     |> assign(title: gettext("Edit Salary Note") <> " " <> obj.note_no)
     |> assign(obj: obj)}
  end

  @impl true
  def handle_event("modal_cancel", _, socket) do
    {:noreply,
     socket
     |> assign(live_action_sn: nil)
     |> assign(live_action_adv: nil)}
  end

  @impl true
  def handle_info({:refresh_page_sn, obj}, socket) do
    {:noreply,
     socket
     |> assign(live_action_sn: nil)
     |> assign(live_action_adv: nil)
     |> assign(shake_obj: obj)
     |> filter_punches(
       socket.assigns.search.month,
       socket.assigns.search.year,
       socket.assigns.employee.name
     )}
  end

  @impl true
  def handle_info({:error_refresh_page_sn, cs}, socket) do
    {:noreply,
     socket
     |> assign(live_action_sn: nil)
     |> assign(live_action_adv: nil)
     |> put_flash(
       :error,
       Enum.map(cs.errors, fn {f, {msg, _}} -> "#{Atom.to_string(f)} #{msg}" end)
     )
     |> filter_punches(
       socket.assigns.search.month,
       socket.assigns.search.year,
       socket.assigns.employee.name
     )}
  end

  @impl true
  def handle_info(
        {:updated_punch, idg, tis, wh, nh, ot},
        socket
      ) do
    [
      {_ti1, id1, st1, fl1, dt1},
      {_ti2, id2, st2, fl2, dt2},
      {_ti3, id3, st3, fl3, dt3},
      {_ti4, id4, st4, fl4, dt4},
      {_ti5, id5, st5, fl5, dt5},
      {_ti6, id6, st6, fl6, dt6}
    ] = tis

    tl = [
      [dt1, id1, st1, fl1],
      [dt2, id2, st2, fl2],
      [dt3, id3, st3, fl3],
      [dt4, id4, st4, fl4],
      [dt5, id5, st5, fl5],
      [dt6, id6, st6, fl6]
    ]

    i = socket.assigns.punches |> Enum.find_index(fn x -> x.idg == idg end)
    old = socket.assigns.punches |> Enum.at(i)
    new = old |> Map.merge(%{time_list: tl, wh: wh, nh: nh, ot: ot})
    punches = socket.assigns.punches |> List.replace_at(i, new)

    {:noreply, socket |> assign(punches: punches) |> update_punch_card(punches)}
  end

  defp filter_punches(socket, month, year, emp_name) do
    emp =
      FullCircle.HR.get_employee_by_name(
        emp_name,
        socket.assigns.current_company,
        socket.assigns.current_user
      )

    if is_nil(emp) do
      socket
      |> assign(punches: [])
      |> assign(salary_notes: [])
      |> assign(advances: [])
      |> assign(employee: nil)
      |> assign(pay_slip: nil)
      |> assign(days_in_month: 0)
      |> assign(sunday_count: 0)
      |> assign(total_day_worked: 0)
      |> assign(ot_day_worked: 0)
      |> assign(normal_pay_days: 0)
      |> assign(sunday_pay_days: 0)
      |> assign(holiday_pay_days: 0)
      |> assign(new_pay_slip_url: nil)
      |> assign(search: %{employee_name: emp_name, month: month, year: year})
    else
      punches =
        HR.punch_card_query(
          month |> String.to_integer(),
          year |> String.to_integer(),
          emp.id,
          socket.assigns.current_company
        )

      salary_notes =
        HR.get_salary_notes(
          emp.id,
          month |> String.to_integer(),
          year |> String.to_integer(),
          socket.assigns.current_company,
          socket.assigns.current_user
        )

      advances =
        HR.get_advances(
          emp.id,
          month |> String.to_integer(),
          year |> String.to_integer(),
          socket.assigns.current_company,
          socket.assigns.current_user
        )

      leaves =
        FullCircle.PayRun.employee_leave_summary(
          emp.id,
          year |> String.to_integer(),
          socket.assigns.current_company
        )

      ps =
        PaySlipOp.get_pay_slip_by_period(
          emp,
          month |> String.to_integer(),
          year |> String.to_integer(),
          socket.assigns.current_company
        )

      qry = %{
        "emp_id" => emp.id,
        "month" => month,
        "year" => year
      }

      socket =
        socket
        |> assign(punches: punches)
        |> assign(employee: emp)
        |> assign(salary_notes: salary_notes)
        |> assign(advances: advances)
        |> assign(leaves: leaves)
        |> assign(pay_slip: ps)
        |> assign(
          new_pay_slip_url:
            "/companies/#{socket.assigns.current_company.id}/PaySlip/new?#{URI.encode_query(qry)}"
        )

      socket |> update_punch_card(punches)
    end
  end

  defp update_punch_card(socket, punches) do
    days_in_month = days_in_month(punches)
    total_day_worked = total_day_worked(punches)
    sunday_count = sunday_count(punches)
    ot_day_worked = ot_day_worked(punches)
    normal_pay_days = normal_pay_days(punches)

    socket
    |> assign(total_day_worked: total_day_worked)
    |> assign(ot_day_worked: ot_day_worked)
    |> assign(days_in_month: days_in_month)
    |> assign(sunday_count: sunday_count)
    |> assign(holiday_pay_days: holiday_pay_days(punches, socket.assigns.current_company.id))
    |> assign(normal_pay_days: normal_pay_days)
    |> assign(
      sunday_pay_days:
        sunday_pay_days(
          total_day_worked,
          ot_day_worked,
          sunday_count,
          days_in_month,
          socket.assigns.employee.work_days_per_week |> Decimal.to_float()
        )
    )
  end

  defp holiday_pay_days(objs, com) do
    Enum.map(objs, fn x ->
      if !is_nil(x.sholi_list) and x.nh > x.work_hours_per_day / 2 do
        px = HR.punch_by_date(x.employee_id, Timex.shift(x.dd, days: -1), com)
        nx = HR.punch_by_date(x.employee_id, Timex.shift(x.dd, days: 1), com)

        if px.wh == 0.0 or nx.wh == 0.0 do
          0.0
        else
          x.nh / x.work_hours_per_day
        end
      else
        0.0
      end
    end)
    |> Enum.sum()
  end

  defp sunday_pay_days(tdw, ot, sc, dim, ewdpw) do
    rest_day_per_week = 7 - ewdpw
    expected_work_days = dim - sc * rest_day_per_week

    dw = tdw - ot
    sw = dw - expected_work_days

    if(sw > 0.0, do: sw, else: 0.0)
  end

  defp normal_pay_days(objs) do
    Enum.map(objs, fn x -> x.nh / x.work_hours_per_day end)
    |> Enum.sum()
  end

  defp sunday_count(objs) do
    Enum.count(objs, fn x -> x.dd |> Timex.weekday() |> Timex.day_shortname() == "Sun" end)
  end

  defp days_in_month(objs) do
    if objs != [], do: Timex.days_in_month(Enum.at(objs, 1).dd), else: 0
  end

  defp total_day_worked(objs) do
    Enum.map(objs, fn x -> x.wh / x.work_hours_per_day end)
    |> Enum.sum()
  end

  defp ot_day_worked(objs) do
    Enum.map(objs, fn x -> x.ot / x.work_hours_per_day end)
    |> Enum.sum()
  end
end
