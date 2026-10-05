defmodule FullCircleWeb.EmployeeLive.Index do
  use FullCircleWeb, :live_view

  import FullCircleWeb.ListComponents

  alias FullCircle.StdInterface
  alias FullCircleWeb.EmployeeLive.IndexComponent
  alias FullCircleWeb.NoteLive.NotesIndex

  @per_page 30
  @selected_max 15

  @impl true
  def render(assigns) do
    ~H"""
    <div class="w-11/12 max-w-6xl mx-auto">
      <.list_bar title={@page_title}>
        <.search_form
          compact
          search_val={@search.terms}
          placeholder={gettext("Name, Id No, Nationality and Status...")}
          live
        />
        <:actions>
          <.link
            :if={@can_print}
            navigate={
              ~p"/companies/#{@current_company.id}/employees/print_multi?pre_print=false&ids=#{@ids}"
            }
            target="_blank"
            class="blue button"
          >
            {gettext("Print QRCode")}{"(#{Enum.count(@selected)})"}
          </.link>
          <.link
            navigate={~p"/companies/#{@current_company.id}/employees/new"}
            class="blue button"
            id="new_employee"
          >
            + {gettext("New Employee")}
          </.link>
        </:actions>
      </.list_bar>

      <.list_table>
        <:head>
          <div class="w-6 shrink-0"></div>
          <div class="flex-1 min-w-0">{gettext("Name")}</div>
          <div class="w-[18%] shrink-0">{gettext("Id No")}</div>
          <div class="w-[16%] shrink-0">{gettext("Nationality")}</div>
          <div class="w-24 shrink-0">{gettext("Status")}</div>
          <div class="w-14 shrink-0"></div>
        </:head>
        <div
          id="objects_list"
          phx-update="stream"
          phx-page-loading
        >
          <%= for {obj_id, obj} <- @streams.objects do %>
            <.live_component
              current_company={@current_company}
              module={IndexComponent}
              note_count={Map.get(@note_counts, obj.id, 0)}
              task_count={Map.get(@task_counts, obj.id, 0)}
              id={obj_id}
              obj={obj}
              ex_class=""
            />
          <% end %>
        </div>
      </.list_table>
      <.infinite_scroll_footer ended={@end_of_timeline?} />
      <NotesIndex.modal
        notes_for={@notes_for}
        notes_type={@notes_type}
        current_company={@current_company}
        current_user={@current_user}
      />
    </div>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(update_action: "stream")
      |> assign(page_title: gettext("Employee Listing"))
      |> NotesIndex.init("Employee", IndexComponent)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    params = params["search"]

    terms = params["terms"] || ""

    {:noreply,
     socket
     |> assign(selected: [])
     |> assign(ids: "")
     |> assign(can_print: false)
     |> assign(update_action: "stream")
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
      |> assign(selected: [id | socket.assigns.selected])
      |> FullCircleWeb.Helpers.can_print?(:selected, @selected_max)

    {:noreply, socket |> assign(ids: Enum.join(socket.assigns.selected, ","))}
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
      |> assign(selected: Enum.reject(socket.assigns.selected, fn sid -> sid == id end))
      |> FullCircleWeb.Helpers.can_print?(:selected, @selected_max)

    {:noreply, socket |> assign(ids: Enum.join(socket.assigns.selected, ","))}
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
    |> NotesIndex.count(objects, reset)
    |> stream(:objects, objects, reset: reset)
    |> assign(end_of_timeline?: Enum.count(objects) < @per_page)
  end
end
