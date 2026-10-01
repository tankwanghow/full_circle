defmodule FullCircleWeb.LayerLive.HarvestIndex do
  use FullCircleWeb, :live_view

  import FullCircleWeb.ListComponents

  alias FullCircleWeb.LayerLive.HarvestIndexComponent
  alias FullCircle.Layer.{Harvest, HarvestDetail, House}
  alias FullCircle.StdInterface

  @per_page 50

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto w-8/12">
      <.form for={%{}} id="search-form" phx-submit="search" autocomplete="off">
        <.list_bar title={@page_title}>
          <div class="grow min-w-56">
            <.filter_label>{gettext("Search Terms")}</.filter_label>
            <.input
              id="search_terms"
              name="search[terms]"
              type="search"
              value={@search.terms}
              placeholder="employee, house..."
            />
          </div>
          <div class="w-36">
            <.filter_label>{gettext("Date From")}</.filter_label>
            <.input
              name="search[har_date]"
              type="date"
              value={@search.har_date}
              id="search_har_date"
            />
          </div>
          <.button class="h-9 w-10">🔍</.button>
          <:actions>
            <.link
              navigate={~p"/companies/#{@current_company.id}/harvests/new"}
              class="blue button"
              id="new_flock"
            >
              + {gettext("New Harvest")}
            </.link>
          </:actions>
        </.list_bar>
      </.form>

      <.list_table gap="gap-0">
        <:head>
          <div class="w-[15%] shrink-0 px-1">{gettext("Date")}</div>
          <div class="w-[15%] shrink-0 px-1">{gettext("Harvest No")}</div>
          <div class="w-[30%] shrink-0 px-1">{gettext("Employee")}</div>
          <div class="w-[40%] shrink-0 px-1">{gettext("Houses")}</div>
        </:head>
        <div
          :if={Enum.count(@streams.objects) > 0 or @page > 1}
          id="objects_list"
          phx-update="stream"
          phx-page-loading
        >
          <%= for {obj_id, obj} <- @streams.objects do %>
            <.live_component
              module={HarvestIndexComponent}
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
      |> assign(page_title: gettext("Harvest Listing"))

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    params = params["search"]
    terms = params["terms"] || ""
    har_date = params["har_date"] || ""

    {:noreply,
     socket
     |> assign(search: %{terms: terms, har_date: har_date})
     |> assign(selected: [])
     |> assign(ids: "")
     |> assign(can_print: false)
     |> filter_objects(terms, true, har_date, 1)}
  end

  @impl true
  def handle_event("next-page", _, socket) do
    {:noreply,
     socket
     |> filter_objects(
       socket.assigns.search.terms,
       false,
       socket.assigns.search.har_date,
       socket.assigns.page + 1
     )}
  end

  @impl true
  def handle_event(
        "search",
        %{
          "search" => %{
            "terms" => terms,
            "har_date" => id
          }
        },
        socket
      ) do
    qry = %{
      "search[terms]" => terms,
      "search[har_date]" => id
    }

    url = "/companies/#{socket.assigns.current_company.id}/harvests?#{URI.encode_query(qry)}"

    {:noreply, socket |> push_navigate(to: url)}
  end

  import Ecto.Query, warn: false

  defp filter_objects(socket, terms, reset, "", page) do
    from(hv in Harvest,
      join: hvd in HarvestDetail,
      on: hvd.harvest_id == hv.id,
      join: h in House,
      on: h.id == hvd.house_id,
      join: emp in FullCircle.HR.Employee,
      on: emp.id == hv.employee_id,
      join:
        com in subquery(
          FullCircle.Sys.user_company(
            socket.assigns.current_company,
            socket.assigns.current_user
          )
        ),
      on: com.id == hv.company_id,
      select: hv,
      select_merge: %{
        employee_name: emp.name,
        houses: fragment("string_agg(distinct ?, ', ')", h.house_no)
      },
      group_by: [hv.id, emp.id],
      order_by: [desc: hv.har_date]
    )
    |> filter(socket, terms, reset, page)
  end

  defp filter_objects(socket, terms, reset, hard, page) do
    from(hv in Harvest,
      join: hvd in HarvestDetail,
      on: hvd.harvest_id == hv.id,
      join: h in House,
      on: h.id == hvd.house_id,
      join: emp in FullCircle.HR.Employee,
      on: emp.id == hv.employee_id,
      join:
        com in subquery(
          FullCircle.Sys.user_company(
            socket.assigns.current_company,
            socket.assigns.current_user
          )
        ),
      on: com.id == hv.company_id,
      where: hv.har_date >= ^hard,
      select: hv,
      select_merge: %{
        employee_name: emp.name,
        houses: fragment("string_agg(distinct ?, ', ')", h.house_no)
      },
      group_by: [hv.id, emp.id],
      order_by: [desc: hv.har_date]
    )
    |> filter(socket, terms, reset, page)
  end

  defp filter(qry, socket, terms, reset, page) do
    objects =
      StdInterface.filter(
        qry,
        [:employee_name, :houses],
        terms,
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
