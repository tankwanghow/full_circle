defmodule FullCircleWeb.TimeAttendLive.PunchIndex do
  use FullCircleWeb, :live_view

  alias FullCircle.HR
  alias FullCircleWeb.TimeAttendLive.PunchIndexComponent

  @per_page 60

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto w-10/12">
      <p class="w-full text-3xl text-center font-medium"><%= @page_title %></p>
      <div class="flex justify-center mb-2">
        <.form for={%{}} id="search-form" phx-submit="search" autocomplete="off" class="w-full">
          <div class=" flex flex-row flex-wrap tracking-tighter text-sm">
            <div class="w-[50%]">
              <.input
                id="search_employee"
                name="search[employee]"
                type="search"
                value={@search.employee}
                label={gettext("Employee Name")}
              />
            </div>
            <div class="w-[20%]">
              <.input
                name="search[sdate]"
                type="date"
                value={@search.sdate}
                id="search_sdate"
                label={gettext("Start Date")}
              />
            </div>
            <div class="w-[20%]">
              <.input
                name="search[edate]"
                type="date"
                value={@search.edate}
                id="search_edate"
                label={gettext("End Date")}
              />
            </div>
            <.button class="mt-5 h-10 w-10 grow-0 shrink-0">🔍</.button>
          </div>
        </.form>
      </div>
      <div class="text-center mb-2">
        <.link phx-click={:new_timeattend} class="blue button" id="new_timeattend">
          <%= gettext("New Time Attendence") %>
        </.link>
      </div>
      <div class="font-medium flex flex-row text-center tracking-tighter bg-amber-200">
        <div class="w-[25%] border-b border-t border-amber-400 py-1">
          <%= gettext("Employee") %>
        </div>
        <div class="w-[15%] border-b border-t border-amber-400 py-1">
          <%= gettext("Date") %>
        </div>
        <div class="w-[10%] border-b border-t border-amber-400 py-1">
          <%= gettext("Year/Week") %>
        </div>
        <div class="w-[10%] border-b border-t border-amber-400 py-1">
          <%= gettext("Shift") %>
        </div>
        <div class="w-[25%] border-b border-t border-amber-400 py-1">
          <%= gettext("Punches") %>
        </div>
        <div class="w-[5%] border-b border-t border-amber-400 py-1">
          <%= gettext("HW") %>
        </div>
        <div class="w-[5%] border-b border-t border-amber-400 py-1">
          <%= gettext("NH") %>
        </div>
        <div class="w-[5%] border-b border-t border-amber-400 py-1">
          <%= gettext("OT") %>
        </div>
      </div>
      <div
        :if={Enum.count(@streams.objects) > 0 or @page > 1}
        id="objects_list"
        phx-update="stream"
        phx-viewport-bottom={!@end_of_timeline? && "next-page"}
        phx-page-loading
      >
        <%= for {obj_id, obj} <- @streams.objects do %>
          <.live_component
            module={PunchIndexComponent}
            id={obj_id}
            obj={obj}
            company={@current_company}
            ex_class=""
          />
        <% end %>
      </div>
      <.infinite_scroll_footer ended={@end_of_timeline?} />
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
      |> assign(page_title: gettext("Punch In/Out Listing"))
      |> assign(
        search: %{
          employee: "",
          sdate: Timex.today(),
          edate: Timex.today() |> Timex.shift(days: 1)
        }
      )
      |> filter_objects("", true, Timex.today(), Timex.today() |> Timex.shift(days: 1), 1)

    {:ok, socket}
  end

  @impl true
  def handle_event("next-page", _, socket) do
    {:noreply,
     socket
     |> filter_objects(
       socket.assigns.search.employee,
       false,
       socket.assigns.search.sdate,
       socket.assigns.search.edate,
       socket.assigns.page + 1
     )}
  end

  @impl true
  def handle_event(
        "search",
        %{
          "search" => %{
            "employee" => employee,
            "sdate" => sd,
            "edate" => ed
          }
        },
        socket
      ) do
    {:noreply,
     socket
     |> assign(search: %{employee: employee, sdate: sd, edate: ed})
     |> filter_objects(employee, true, sd, ed, 1)}
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

    send_update(self(), FullCircleWeb.TimeAttendLive.PunchIndexComponent,
      id: socket.assigns.comp_id,
      company: socket.assigns.current_company,
      obj: obj,
      ex_class: "shake"
    )

    send_update_after(
      self(),
      FullCircleWeb.TimeAttendLive.PunchIndexComponent,
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
      FullCircleWeb.TimeAttendLive.PunchIndexComponent,
      id: "#{obj.id}",
      company: socket.assigns.current_company,
      obj: obj,
      ex_class: "shake"
    )

    send_update_after(
      self(),
      FullCircleWeb.TimeAttendLive.PunchIndexComponent,
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

    send_update(self(), FullCircleWeb.TimeAttendLive.PunchIndexComponent,
      id: socket.assigns.comp_id,
      obj: obj,
      company: socket.assigns.current_company,
      ex_class: "shake"
    )

    send_update_after(
      self(),
      FullCircleWeb.TimeAttendLive.PunchIndexComponent,
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

  defp filter_objects(socket, employee, reset, sdate, edate, page) do
    objects =
      if sdate == "" or edate == "" do
        []
      else
        HR.punch_query(
          sdate,
          edate,
          employee,
          socket.assigns.current_company.id,
          page: page,
          per_page: @per_page
        )
      end

    obj_count = Enum.count(objects)

    socket
    |> assign(page: page, per_page: @per_page)
    |> stream(:objects, objects, reset: reset)
    |> assign(end_of_timeline?: obj_count < @per_page)
  end
end
