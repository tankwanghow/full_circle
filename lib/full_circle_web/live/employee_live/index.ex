defmodule FullCircleWeb.EmployeeLive.Index do
  use FullCircleWeb, :live_view

  # alias FullCircle.HR.Employee
  alias FullCircle.StdInterface
  alias FullCircleWeb.EmployeeLive.IndexComponent

  @per_page 30

  @impl true
  def render(assigns) do
    ~H"""
    <div class="w-5/12 mx-auto">
      <p class="w-full text-3xl text-center font-medium"><%= @page_title %></p>
      <.search_form
        search_val={@search.terms}
        placeholder={gettext("Name, Id No, Nationality and Status...")}
      />
      <div class="text-center mb-2">
        <.link
          navigate={~p"/companies/#{@current_company.id}/employees/new"}
          class="blue button"
          id="new_object"
        >
          <%= gettext("New Employee") %>
        </.link>
        <.link
          :if={@ids != ""}
          navigate={
            ~p"/companies/#{@current_company.id}/employees/print_multi?pre_print=false&ids=#{@ids}"
          }
          target="_blank"
          class="blue button"
        >
          <%= gettext("Print QRCode") %>
        </.link>
      </div>
      <div class="text-center mb-1">
        <div class="rounded bg-amber-200 border border-amber-500 font-bold p-2">
          <%= gettext("Employee Information") %>
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
            current_company={@current_company}
            module={IndexComponent}
            id={"#{obj_id}"}
            obj={obj}
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
      |> assign(page_title: gettext("Employee Listing"))

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    params = params["search"]

    terms = params["terms"] || ""

    {:noreply,
     socket
     |> assign(selected_employees: [])
     |> assign(ids: "")
     |> assign(search: %{terms: terms})
     |> filter_objects(terms, true, 1)}
  end

  @impl true
  def handle_event("next-page", _, socket) do
    {:noreply,
     socket
     |> filter_objects(socket.assigns.search.terms, false, socket.assigns.page + 1)}
  end

  @impl true
  def handle_event("search", %{"search" => %{"terms" => terms}}, socket) do
    qry = %{
      "search[terms]" => terms
    }

    url = "/companies/#{socket.assigns.current_company.id}/employees?#{URI.encode_query(qry)}"

    {:noreply, socket |> push_patch(to: url)}
  end

  @impl true
  def handle_event("check_click", %{"object-id" => id, "value" => "on"}, socket) do
    obj =
      FullCircle.HR.get_employee_by_id_index_component_field!(
        id,
        socket.assigns.current_company,
        socket.assigns.current_user
      )

    Phoenix.LiveView.send_update(
      self(),
      IndexComponent,
      [{:id, "objects-#{id}"}, {:obj, Map.merge(obj, %{checked: true})}]
    )

    socket =
      socket
      |> assign(selected_employees: [id | socket.assigns.selected_employees])

    {:noreply, socket |> assign(ids: Enum.join(socket.assigns.selected_employees, ","))}
  end

  @impl true
  def handle_event("check_click", %{"object-id" => id}, socket) do
    obj =
      FullCircle.HR.get_employee_by_id_index_component_field!(
        id,
        socket.assigns.current_company,
        socket.assigns.current_user
      )

    Phoenix.LiveView.send_update(
      self(),
      IndexComponent,
      [{:id, "objects-#{id}"}, {:obj, Map.merge(obj, %{checked: false})}]
    )

    socket =
      socket
      |> assign(
        selected_employees:
          Enum.reject(socket.assigns.selected_employees, fn sid -> sid == id end)
      )

    {:noreply, socket |> assign(ids: Enum.join(socket.assigns.selected_employees, ","))}
  end

  defp filter_objects(socket, terms, reset, page) when page >= 1 do
    query =
      FullCircle.HR.employee_checked_query(
        socket.assigns.current_company,
        socket.assigns.current_user
      )

    objects =
      StdInterface.filter(
        query,
        [:name, :status, :id_no, :nationality],
        terms,
        page: page,
        per_page: @per_page
      )

    socket
    |> assign(page: page, per_page: @per_page)
    |> stream(:objects, objects, reset: reset)
    |> assign(end_of_timeline?: Enum.count(objects) < @per_page)
  end
end
