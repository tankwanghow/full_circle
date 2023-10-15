defmodule FullCircleWeb.TimeAttendLive.PunchCard do
  use FullCircleWeb, :live_view

  alias FullCircle.HR
  alias FullCircleWeb.TimeAttendLive.{PunchCardComponent, SalaryNoteComponent}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto w-8/12">
      <p class="w-full text-3xl text-center font-medium"><%= @page_title %></p>

      <.form
        for={%{}}
        id="search-form"
        phx-submit="search"
        autocomplete="off"
        class="mx-auto w-11/12 mb-2"
      >
        <div class=" flex flex-row gap-1 justify-center">
          <div class="w-[42%]">
            <.input
              id="search_employee_name"
              name="search[employee_name]"
              type="search"
              value={@search.employee_name}
              label={gettext("Employee")}
              phx-hook="tributeAutoComplete"
              phx-debounce="500"
              url={"/api/companies/#{@current_company.id}/#{@current_user.id}/autocomplete?schema=employee&name="}
            />
          </div>
          <div class="w-[11%]">
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
          <div class="w-[11%]">
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
          <.button class="w-[7%] mt-5 h-10 grow-0 shrink-0">🔍</.button>
          <.link
            :if={@search.employee_name != ""}
            phx-click={:new_timeattend}
            class="w-[17%] h-10 mt-5 blue button"
            id="new_timeattend"
          >
            <%= gettext("New Attendence") %>
          </.link>
          <.link
            :if={@search.employee_name != ""}
            phx-click={:new_salarynote}
            class="w-[12%] h-10 mt-5 blue button"
            id="new_salarynote"
          >
            <%= gettext("New Note") %>
          </.link>
        </div>
      </.form>

      <div class="flex flex-row justify-around gap-2 h-8 w-full mb-2 border-y border-purple-600 bg-purple-200">
        <span class="mt-1">
          Total:
          <span class="font-bold text-orange-600">
            <%= @total_day_worked |> Number.Delimit.number_to_delimited() %>
          </span>
        </span>
        <span class="mt-1">
          Overtime:
          <span class="font-bold text-orange-600">
            <%= @ot_day_worked |> Number.Delimit.number_to_delimited() %>
          </span>
        </span>
        <span class="mt-1">
          Normal:
          <.link
            class="text-blue-600 hover:font-bold"
            phx-value-qty={@normal_pay_days |> Number.Delimit.number_to_delimited()}
            phx-click={:new_salarynote_with_qty}
          >
            <%= @normal_pay_days |> Number.Delimit.number_to_delimited() %>
          </.link>
        </span>
        <span class="mt-1">
          Sunday:
          <.link
            class="text-blue-600 hover:font-bold"
            phx-value-qty={@sunday_pay_days |> Number.Delimit.number_to_delimited()}
            phx-click={:new_salarynote_with_qty}
          >
            <%= @sunday_pay_days |> Number.Delimit.number_to_delimited() %>
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
            class="text-blue-600 hover:font-bold"
            phx-value-qty={@holiday_pay_days |> Number.Delimit.number_to_delimited()}
            phx-click={:new_salarynote_with_qty}
          >
            <%= @holiday_pay_days |> Number.Delimit.number_to_delimited() %>
          </.link>
        </span>
      </div>

      <div class="font-medium flex flex-row text-center tracking-tighter bg-blue-200">
        <div class="w-[11%] border-b border-t border-blue-400 py-1">
          <%= gettext("Date") %>
        </div>
        <div class="w-[11%] border-b border-t border-blue-400 py-1">
          <%= gettext("Note No") %>
        </div>
        <div class="w-[22%] border-b border-t border-blue-400 py-1">
          <%= gettext("Salary Type") %>
        </div>
        <div class="w-[29%] border-b border-t border-blue-400 py-1">
          <%= gettext("Descriptions") %>
        </div>
        <div class="w-[9%] border-b border-t border-blue-400 py-1">
          <%= gettext("Quantity") %>
        </div>
        <div class="w-[9%] border-b border-t border-blue-400 py-1">
          <%= gettext("Price") %>
        </div>
        <div class="w-[9%] border-b border-t border-blue-400 py-1">
          <%= gettext("Amount") %>
        </div>
      </div>
      <div id="notes_list" class="mb-5">
        <%= for obj <- @salary_notes do %>
          <.live_component
            module={SalaryNoteComponent}
            id={obj.id}
            obj={obj}
            company={@current_company}
            ex_class=""
          />
        <% end %>
      </div>

      <div class="font-medium flex flex-row text-center tracking-tighter bg-amber-200">
        <div class="w-[20%] border-b border-t border-amber-400 py-1">
          <%= gettext("Date") %>
        </div>
        <div class="w-[15%] border-b border-t border-amber-400 py-1">
          <%= gettext("Year/Week") %>
        </div>
        <div class="w-[12%] border-b border-t border-amber-400 py-1">
          <%= gettext("Shift") %>
        </div>
        <div class="w-[32%] border-b border-t border-amber-400 py-1">
          <%= gettext("Punches") %>
        </div>
        <div class="w-[7%] border-b border-t border-amber-400 py-1">
          <%= gettext("HW") %>
        </div>
        <div class="w-[7%] border-b border-t border-amber-400 py-1">
          <%= gettext("NH") %>
        </div>
        <div class="w-[7%] border-b border-t border-amber-400 py-1">
          <%= gettext("OT") %>
        </div>
      </div>
      <div id="objects_list" class="mb-5">
        <%= for obj <- @objects do %>
          <.live_component
            module={PunchCardComponent}
            id={obj.id}
            obj={obj}
            company={@current_company}
            ex_class=""
          />
        <% end %>
      </div>
    </div>
    <.modal
      :if={@live_action_ta in [:new, :edit]}
      id="timeattend-modal"
      show
      on_cancel={JS.push("modal_cancel")}
      max_w="max-w-4xl"
    >
      <.live_component
        module={FullCircleWeb.TimeAttendLive.FormComponent}
        live_action={@live_action_ta}
        id={@obj.id || :new}
        obj={@obj}
        title={@title}
        action={@live_action_ta}
        current_company={@current_company}
        current_user={@current_user}
      />
    </.modal>
    <.modal
      :if={@live_action_sn in [:new, :edit]}
      id="salarynote-modal"
      show
      on_cancel={JS.push("modal_cancel")}
      max_w="max-w-3xl"
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
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(page_title: gettext("Punch Card"))
      |> assign(objects: [])
      |> assign(salary_notes: [])
      |> assign(days_in_month: 0)
      |> assign(sunday_count: 0)
      |> assign(total_day_worked: 0)
      |> assign(ot_day_worked: 0)
      |> assign(normal_pay_days: 0)
      |> assign(sunday_pay_days: 0)
      |> assign(holiday_pay_days: 0)
      |> assign(employee: %{id: nil, name: nil, work_days_per_week: 0})
      |> assign(live_action_ta: :index)
      |> assign(live_action_sn: :index)
      |> assign(
        search: %{employee_name: "", month: Timex.today().month, year: Timex.today().year}
      )

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
    emp =
      FullCircle.HR.get_employee_by_name(
        name,
        socket.assigns.current_company,
        socket.assigns.current_user
      )

    emp = emp || %{id: nil, name: nil}

    {:noreply,
     socket
     |> assign(search: %{employee_name: emp.name, month: month, year: year})
     |> assign(employee: emp)
     |> filter_objects(month, year, emp.id)}
  end

  def handle_event("new_salarynote", _, socket) do
    {:noreply,
     socket
     |> assign(live_action_sn: :new)
     |> assign(id: "new")
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

  def handle_event("new_salarynote_with_qty", %{"qty" => qty}, socket) do
    {:noreply,
     socket
     |> assign(live_action_sn: :new)
     |> assign(id: "new")
     |> assign(title: gettext("New Salary Note"))
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
     |> assign(title: gettext("Edit Salary Note") <> " " <> obj.note_no)
     |> assign(obj: obj)}
  end

  def handle_event("new_timeattend", _, socket) do
    {:noreply,
     socket
     |> assign(live_action_ta: :new)
     |> assign(obj: %FullCircle.HR.TimeAttend{employee_name: socket.assigns.employee.name})
     |> assign(title: gettext("New Attendence"))}
  end

  @impl true
  def handle_event("edit_timeattend", params, socket) do
    ta =
      HR.get_time_attendence!(
        params["id"],
        socket.assigns.current_company,
        socket.assigns.current_user
      )

    {:noreply,
     socket
     |> assign(live_action_ta: :edit)
     |> assign(comp_id: params["comp-id"])
     |> assign(obj: ta)
     |> assign(title: gettext("Edit Attendence"))}
  end

  @impl true
  def handle_event("modal_cancel", _, socket) do
    {:noreply, socket |> assign(live_action_ta: nil) |> assign(live_action_sn: nil)}
  end

  @impl true
  def handle_info({:deleted_sn, obj}, socket) do
    salary_notes =
      HR.get_salary_notes(
        obj.employee_id,
        socket.assigns.search.month,
        socket.assigns.search.year,
        socket.assigns.current_company,
        socket.assigns.current_user
      )

    {:noreply,
     socket
     |> assign(live_action_sn: nil)
     |> assign(salary_notes: salary_notes)
     |> put_flash(:success, "#{gettext("Deleted!!")}")}
  end

  @impl true
  def handle_info({:created_sn, obj}, socket) do
    salary_notes =
      HR.get_salary_notes(
        obj.employee_id,
        socket.assigns.search.month,
        socket.assigns.search.year,
        socket.assigns.current_company,
        socket.assigns.current_user
      )

    send_update(self(), FullCircleWeb.TimeAttendLive.SalaryNoteComponent,
      id: obj.id,
      current_company: socket.assigns.current_company,
      obj: obj,
      ex_class: "shake"
    )

    send_update_after(
      self(),
      FullCircleWeb.TimeAttendLive.SalaryNoteFormComponent,
      [
        id: obj.id,
        current_company: socket.assigns.current_company,
        obj: obj,
        ex_class: ""
      ],
      1000
    )

    {:noreply,
     socket
     |> assign(live_action_sn: nil)
     |> assign(salary_notes: salary_notes)
     |> put_flash(:success, "#{gettext("Created!!")}")}
  end

  @impl true
  def handle_info({:updated_sn, obj}, socket) do
    obj = HR.get_salary_note!(obj.id, socket.assigns.current_company, socket.assigns.current_user)

    send_update(self(), FullCircleWeb.TimeAttendLive.SalaryNoteComponent,
      id: obj.id,
      current_company: socket.assigns.current_company,
      obj: obj,
      ex_class: "shake"
    )

    send_update_after(
      self(),
      FullCircleWeb.TimeAttendLive.SalaryNoteFormComponent,
      [
        id: obj.id,
        current_company: socket.assigns.current_company,
        obj: obj,
        ex_class: ""
      ],
      1000
    )

    {:noreply,
     socket
     |> assign(live_action_sn: nil)
     |> put_flash(:success, "#{gettext("Updated!!")}")}
  end

  @impl true
  def handle_info({:deleted_ta, obj}, socket) do
    obj = HR.punch_query_by_id(obj.employee_id, obj.punch_time, socket.assigns.current_company.id)

    send_update(self(), FullCircleWeb.TimeAttendLive.PunchCardComponent,
      id: socket.assigns.comp_id,
      company: socket.assigns.current_company,
      obj: obj,
      ex_class: "shake"
    )

    send_update_after(
      self(),
      FullCircleWeb.TimeAttendLive.PunchCardComponent,
      [
        id: socket.assigns.comp_id,
        company: socket.assigns.current_company,
        obj: obj,
        ex_class: ""
      ],
      1000
    )

    {:noreply,
     socket
     |> assign(live_action_ta: nil)
     |> put_flash(:success, "#{gettext("Deleted!!")}")}
  end

  @impl true
  def handle_info({:created_ta, obj}, socket) do
    obj = HR.punch_query_by_id(obj.employee_id, obj.punch_time, socket.assigns.current_company.id)

    send_update(
      self(),
      FullCircleWeb.TimeAttendLive.PunchCardComponent,
      id: "#{obj.id}",
      company: socket.assigns.current_company,
      obj: obj,
      ex_class: "shake"
    )

    send_update_after(
      self(),
      FullCircleWeb.TimeAttendLive.PunchCardComponent,
      [
        id: "#{obj.id}",
        company: socket.assigns.current_company,
        obj: obj,
        ex_class: ""
      ],
      1000
    )

    {:noreply, socket |> assign(live_action_ta: nil)}
  end

  @impl true
  def handle_info({:updated_ta, obj}, socket) do
    obj = HR.punch_query_by_id(obj.employee_id, obj.punch_time, socket.assigns.current_company.id)

    send_update(self(), FullCircleWeb.TimeAttendLive.PunchCardComponent,
      id: socket.assigns.comp_id,
      obj: obj,
      company: socket.assigns.current_company,
      ex_class: "shake"
    )

    send_update_after(
      self(),
      FullCircleWeb.TimeAttendLive.PunchCardComponent,
      [
        id: socket.assigns.comp_id,
        company: socket.assigns.current_company,
        obj: obj,
        ex_class: ""
      ],
      1000
    )

    {:noreply, socket |> assign(live_action_ta: nil)}
  end

  defp filter_objects(socket, month, year, emp_id) do
    {objects, salary_notes} =
      if !is_nil(emp_id) do
        {
          HR.punch_card_query(
            month,
            year,
            emp_id,
            socket.assigns.current_company.id
          ),
          HR.get_salary_notes(
            emp_id,
            month,
            year,
            socket.assigns.current_company,
            socket.assigns.current_user
          )
        }
      else
        {[], []}
      end

    socket =
      socket
      |> assign(objects: objects)
      |> assign(salary_notes: salary_notes)
      |> assign(total_day_worked: total_day_worked(objects))
      |> assign(ot_day_worked: ot_day_worked(objects))
      |> assign(days_in_month: days_in_month(objects))
      |> assign(sunday_count: sunday_count(objects))
      |> assign(holiday_pay_days: holiday_pay_days(objects, socket.assigns.current_company.id))

    socket
    |> assign(
      normal_pay_days:
        normal_pay_days(
          socket.assigns.employee.work_days_per_week,
          socket.assigns.days_in_month,
          socket.assigns.sunday_count,
          socket.assigns.total_day_worked
        )
    )
    |> assign(
      sunday_pay_days:
        sunday_pay_days(
          socket.assigns.employee.work_days_per_week,
          socket.assigns.days_in_month,
          socket.assigns.sunday_count,
          socket.assigns.total_day_worked
        )
    )
  end

  defp holiday_pay_days(objs, com_id) do
    Enum.map(objs, fn x ->
      if !is_nil(x.sholi_list) and x.nh / x.normal_work_hours > 0 do
        px = HR.punch_by_date(x.employee_id, Timex.shift(x.dd, days: -1), com_id)
        nx = HR.punch_by_date(x.employee_id, Timex.shift(x.dd, days: 1), com_id)

        if px.wh == 0 or nx.wh == 0 do
          0
        else
          x.nh / x.normal_work_hours
        end
      else
        0
      end
    end)
    |> Enum.sum()
  end

  defp sunday_pay_days(ewdpw, dim, sc, tdw) do
    rest_day_per_week = 7 - ewdpw
    expected_work_days = dim - sc * rest_day_per_week

    cond do
      tdw > expected_work_days -> tdw - expected_work_days
      tdw <= expected_work_days -> 0
    end
  end

  defp normal_pay_days(ewdpw, dim, sc, tdw) do
    rest_day_per_week = 7 - ewdpw
    expected_work_days = dim - sc * rest_day_per_week

    cond do
      tdw > expected_work_days -> expected_work_days
      tdw <= expected_work_days -> tdw
    end
  end

  defp sunday_count(objs) do
    Enum.count(objs, fn x -> x.dd |> Timex.weekday() |> Timex.day_shortname() == "Sun" end)
  end

  defp days_in_month(objs) do
    if objs != [], do: Timex.days_in_month(Enum.at(objs, 1).dd), else: 0
  end

  defp total_day_worked(objs) do
    Enum.map(objs, fn x -> x.nh / x.normal_work_hours end)
    |> Enum.sum()
  end

  defp ot_day_worked(objs) do
    Enum.map(objs, fn x -> x.ot / x.normal_work_hours end)
    |> Enum.sum()
  end
end
