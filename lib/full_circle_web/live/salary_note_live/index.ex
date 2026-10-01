defmodule FullCircleWeb.SalaryNoteLive.Index do
  use FullCircleWeb, :live_view

  import FullCircleWeb.ListComponents

  alias FullCircle.HR
  alias FullCircleWeb.SalaryNoteLive.IndexComponent

  @per_page 25
  @selected_max 15

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto w-10/12">
      <.form for={%{}} id="search-form" phx-submit="search" autocomplete="off">
        <.list_bar title={@page_title}>
          <div class="grow min-w-56">
            <.filter_label>{gettext("Search Terms")}</.filter_label>
            <.input
              id="search_terms"
              name="search[terms]"
              type="search"
              value={@search.terms}
              placeholder="note no, employee, salary type or descriptions..."
            />
          </div>
          <div class="w-36">
            <.filter_label>{gettext("Note Date From")}</.filter_label>
            <.input
              name="search[note_date]"
              type="date"
              value={@search.note_date}
              id="search_note_date"
            />
          </div>
          <.button class="h-9 w-10">🔍</.button>
          <:actions>
            <.link
              :if={@can_print}
              navigate={
                ~p"/companies/#{@current_company.id}/SalaryNote/print_multi?pre_print=false&ids=#{@ids}"
              }
              target="_blank"
              class="blue button"
            >
              {gettext("Print")}{"(#{Enum.count(@selected)})"}
            </.link>
            <.link
              :if={@can_print}
              navigate={
                ~p"/companies/#{@current_company.id}/SalaryNote/print_multi?pre_print=true&ids=#{@ids}"
              }
              target="_blank"
              class="blue button"
            >
              {gettext("Pre Print")}{"(#{Enum.count(@selected)})"}
            </.link>
            <.link
              navigate={~p"/companies/#{@current_company.id}/SalaryNote/new"}
              class="blue button"
              id="new_advance"
            >
              + {gettext("New Salary Note")}
            </.link>
          </:actions>
        </.list_bar>
      </.form>

      <.list_table gap="gap-0">
        <:head>
          <div class="w-6 shrink-0 text-center"></div>
          <div class="w-[10%] shrink-0 px-1">{gettext("Date")}</div>
          <div class="w-[10%] shrink-0 px-1">{gettext("Note No")}</div>
          <div class="w-[10%] shrink-0 px-1">{gettext("Slip No")}</div>
          <div class="w-[16%] shrink-0 px-1">{gettext("Employee")}</div>
          <div class="w-[16%] shrink-0 px-1">{gettext("Salary Type")}</div>
          <div class="w-[26%] shrink-0 px-1">{gettext("Descriptions")}</div>
          <div class="w-[10%] shrink-0 px-1 text-right tabular-nums">{gettext("Amount")}</div>
        </:head>
        <div
          :if={Enum.count(@streams.objects) > 0 or @page > 1}
          id="objects_list"
          phx-update="stream"
          phx-page-loading
        >
          <%= for {obj_id, obj} <- @streams.objects do %>
            <.live_component
              module={IndexComponent}
              id={obj_id}
              obj={obj}
              company={@current_company}
              ex_class=""
            />
          <% end %>
        </div>
      </.list_table>
      <.infinite_scroll_footer ended={@end_of_timeline?} />
    </div>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(page_title: gettext("Salary Note Listing"))

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    params = params["search"]
    terms = params["terms"] || ""
    note_date = params["note_date"] || ""

    {:noreply,
     socket
     |> assign(search: %{terms: terms, note_date: note_date})
     |> assign(selected: [])
     |> assign(ids: "")
     |> assign(can_print: false)
     |> filter_objects(terms, true, note_date, 1)}
  end

  @impl true
  def handle_event("check_click", %{"object-id" => id, "value" => "on"}, socket) do
    obj =
      FullCircle.HR.get_salary_note_by_id_index_component_field!(
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
      FullCircle.HR.get_salary_note_by_id_index_component_field!(
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

  @impl true
  def handle_event("next-page", _, socket) do
    {:noreply,
     socket
     |> filter_objects(
       socket.assigns.search.terms,
       false,
       socket.assigns.search.note_date,
       socket.assigns.page + 1
     )}
  end

  @impl true
  def handle_event(
        "search",
        %{
          "search" => %{
            "terms" => terms,
            "note_date" => id
          }
        },
        socket
      ) do
    qry = %{
      "search[terms]" => terms,
      "search[note_date]" => id
    }

    url = "/companies/#{socket.assigns.current_company.id}/SalaryNote?#{URI.encode_query(qry)}"

    {:noreply, socket |> push_navigate(to: url)}
  end

  defp filter_objects(socket, terms, reset, note_date, page) do
    objects =
      HR.salary_note_index_query(
        terms,
        note_date,
        socket.assigns.current_company,
        socket.assigns.current_user,
        page: page,
        per_page: @per_page
      )

    obj_count = Enum.count(objects)

    socket
    |> assign(page: page, per_page: @per_page)
    |> stream(:objects, objects, reset: reset)
    |> assign(end_of_timeline?: obj_count < @per_page)
  end
end
