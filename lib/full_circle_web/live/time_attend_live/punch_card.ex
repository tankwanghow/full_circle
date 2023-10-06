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
        <.form for={%{}} id="search-form" phx-submit="search" autocomplete="off" class="w-full">
          <div class=" flex flex-row flex-wrap tracking-tighter text-sm">
            <div class="w-[50%]">
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
            <div class="w-[20%]">
              <.input
                name="search[month]"
                type="number"
                value={@search.month}
                id="search_month"
                label={gettext("Month")}
              />
            </div>
            <div class="w-[20%]">
              <.input
                name="search[year]"
                type="number"
                value={@search.year}
                id="search_year"
                label={gettext("Year")}
              />
            </div>
            <.button class="mt-5 h-10 w-10 grow-0 shrink-0">🔍</.button>
          </div>
        </.form>
      </div>
      <div class="text-center mb-2">
        <.link
          navigate={~p"/companies/#{@current_company.id}/TimeAttend/new"}
          class="blue button"
          id="new_timeattend"
        >
          <%= gettext("New Time Attendence") %>
        </.link>
      </div>
      <div class="font-medium flex flex-row text-center tracking-tighter bg-amber-200">
      <div class="w-[15%] border-b border-t border-amber-400 py-1">
          <%= gettext("Date") %>
        </div>
        <div class="w-[15%] border-b border-t border-amber-400 py-1">
          <%= gettext("Year/Week") %>
        </div>
        <div class="w-[10%] border-b border-t border-amber-400 py-1">
          <%= gettext("Shift") %>
        </div>
        <div class="w-[36%] border-b border-t border-amber-400 py-1">
          <%= gettext("Punches") %>
        </div>
        <div class="w-[8%] border-b border-t border-amber-400 py-1">
          <%= gettext("HW") %>
        </div>
        <div class="w-[8%] border-b border-t border-amber-400 py-1">
          <%= gettext("NH") %>
        </div>
        <div class="w-[8%] border-b border-t border-amber-400 py-1">
          <%= gettext("OT") %>
        </div>
      </div>
      <div id="objects_list" class="mb-5">
        <%= for obj <- @objects do %>
          <.live_component
            module={PunchCardComponent}
            id={"object_#{obj.id}"}
            obj={obj}
            company={@current_company}
          />
        <% end %>
      </div>
    </div>
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
