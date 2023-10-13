defmodule FullCircleWeb.TimeAttendLive.PunchCard do
  use FullCircleWeb, :live_view

  alias FullCircle.HR
  alias FullCircleWeb.TimeAttendLive.PunchCardComponent

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto w-8/12">
      <p class="w-full text-3xl text-center font-medium"><%= @page_title %></p>
      <div class="flex justify-center mb-2">
        <.form
          for={%{}}
          id="search-form"
          phx-submit="search"
          autocomplete="off"
          class="mx-auto w-11/12"
        >
          <div class="flex flex-row flex-wrap gap-1">
            <div class="w-[40%]">
              <.input
                id="search_employee"
                name="search[employee]"
                type="search"
                value={@search.employee}
                label={gettext("Employee")}
                phx-hook="tributeAutoComplete"
                phx-debounce="500"
                url={"/api/companies/#{@current_company.id}/#{@current_user.id}/autocomplete?schema=employee&name="}
              />
            </div>
            <div class="w-[10%]">
              <.input
                name="search[month]"
                type="number"
                value={@search.month}
                id="search_month"
                label={gettext("Month")}
              />
            </div>
            <div class="w-[10%]">
              <.input
                name="search[year]"
                type="number"
                value={@search.year}
                id="search_year"
                label={gettext("Year")}
              />
            </div>
            <.button class="w-[6%] mt-5 h-10 grow-0 shrink-0">🔍</.button>
            <.link
              phx-click={:new_timeattend}
              class="w-[30%] h-10 mt-5 blue button"
              id="new_timeattend"
            >
              <%= gettext("New Time Attendence") %>
            </.link>
          </div>
        </.form>
      </div>

      <div class="flex flex-row justify-center gap-2">
        <div class="h-8 w-5/12 mb-2 border-y border-orange-600 bg-orange-200">
          <span class="mt-1 ml-2 float-left font-light">
            Normal:
            <span class="font-medium">
              <%= Enum.map(@objects, fn x -> x.nh end)
              |> Enum.sum()
              |> Number.Delimit.number_to_delimited() %>(hours)
            </span>
          </span>
          <span class="mr-2 mt-1 font-light float-right">
            Overtime:
            <span class="font-medium">
              <%= Enum.map(@objects, fn x -> x.ot end)
              |> Enum.sum()
              |> Number.Delimit.number_to_delimited() %>(hours)
            </span>
          </span>
        </div>
        <div class="h-8 w-5/12 mb-2 border-y border-purple-600 bg-purple-200">
          <span class="mt-1 ml-2 float-left font-light">
            Normal:
            <span class="font-medium">
              <%= Enum.map(@objects, fn x -> x.nh / x.normal_work_hours end)
              |> Enum.sum()
              |> Number.Delimit.number_to_delimited() %>(days)
            </span>
          </span>
          <span class="mr-2 mt-1 font-light float-right">
            Overtime:
            <span class="font-medium">
              <%= Enum.map(@objects, fn x -> x.ot / x.normal_work_hours end)
              |> Enum.sum()
              |> Number.Delimit.number_to_delimited() %>(days)
            </span>
          </span>
        </div>
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
      :if={@live_action in [:new, :edit]}
      id="timeattend-modal"
      show
      on_cancel={JS.push("modal_cancel")}
      max_w="max-w-5xl"
    >
      <.live_component
        module={FullCircleWeb.TimeAttendLive.FormComponent}
        live_action={@live_action}
        id={@obj.id || :new}
        obj={@obj}
        title={@title}
        action={@live_action}
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
      |> assign(search: %{employee: "", month: Timex.today().month, year: Timex.today().year})

    {:ok, socket}
  end

  @impl true
  def handle_event(
        "search",
        %{
          "search" => %{
            "employee" => employee,
            "month" => month,
            "year" => year
          }
        },
        socket
      ) do
    emp =
      FullCircle.HR.get_employee_by_name(
        employee,
        socket.assigns.current_company,
        socket.assigns.current_user
      )

    emp_id = if emp, do: emp.id, else: nil

    {:noreply, socket |> filter_objects(month, year, emp_id)}
  end

  def handle_event("new_timeattend", _, socket) do
    {:noreply,
     socket
     |> assign(live_action: :new)
     |> assign(obj: %FullCircle.HR.TimeAttend{})
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
     |> assign(live_action: :edit)
     |> assign(comp_id: params["comp-id"])
     |> assign(obj: ta)
     |> assign(title: gettext("Edit Attendence"))}
  end

  @impl true
  def handle_event("modal_cancel", _, socket) do
    {:noreply, socket |> assign(live_action: nil)}
  end

  @impl true
  def handle_info({:deleted, obj}, socket) do
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
     |> assign(live_action: nil)
     |> put_flash(:success, "#{gettext("Deleted!!")}")}
  end

  @impl true
  def handle_info({:created, obj}, socket) do
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

    {:noreply, socket |> assign(live_action: nil)}
  end

  @impl true
  def handle_info({:updated, obj}, socket) do
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

    {:noreply, socket |> assign(live_action: nil)}
  end

  defp filter_objects(socket, month, year, emp_id) do
    objects =
      HR.punch_card_query(
        month,
        year,
        emp_id,
        socket.assigns.current_company.id
      )

    socket
    |> assign(objects: objects)
  end
end
