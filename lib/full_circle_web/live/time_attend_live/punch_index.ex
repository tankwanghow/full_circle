defmodule FullCircleWeb.TimeAttendLive.PunchIndex do
  use FullCircleWeb, :live_view

  alias FullCircle.HR
  alias FullCircleWeb.TimeAttendLive.PunchIndexComponent

  @per_page 60

  @impl true
  def render(assigns) do
    ~H"""
    <div id="punchIOIndex" class="mx-auto w-10/12">
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
        <div class="w-[50%] flex flex-row border-b border-t border-amber-400 py-1">
          <div class="w-[66%]">
            <%= gettext("Punches") %>
          </div>
          <div class="w-[12%]">
            <%= gettext("HW") %>
          </div>
          <div class="w-[11%]">
            <%= gettext("NH") %>
          </div>
          <div class="w-[11%]">
            <%= gettext("OT") %>
          </div>
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
            user={@current_user}
            ex_class=""
          />
        <% end %>
      </div>
      <.infinite_scroll_footer ended={@end_of_timeline?} />
    </div>
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
  def handle_event("edit_click", _, socket) do
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
  def handle_event("lock_click", _, socket) do
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
