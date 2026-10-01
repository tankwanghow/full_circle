defmodule FullCircleWeb.RecurringLive.Index do
  use FullCircleWeb, :live_view

  import FullCircleWeb.ListComponents

  alias FullCircle.HR
  alias FullCircle.StdInterface
  alias FullCircleWeb.RecurringLive.IndexComponent

  @per_page 30

  @impl true
  def render(assigns) do
    ~H"""
    <div class="w-11/12 max-w-6xl mx-auto">
      <.list_bar title={@page_title}>
        <.search_form
          compact
          search_val={@search.terms}
          placeholder={gettext("recurring, employee, salary type or status...")}
        />
        <:actions>
          <.link
            navigate={~p"/companies/#{@current_company.id}/recurrings/new"}
            class="blue button"
            id="new_object"
          >
            + {gettext("New Recurring")}
          </.link>
        </:actions>
      </.list_bar>

      <.list_table>
        <:head>
          <div class="w-[14%] shrink-0">{gettext("No.")}</div>
          <div class="w-28 shrink-0">{gettext("Date")}</div>
          <div class="flex-1 min-w-0">{gettext("Employee")}</div>
          <div class="w-[22%] shrink-0">{gettext("Salary type")}</div>
          <div class="w-28 shrink-0">{gettext("Start")}</div>
          <div class="w-24 shrink-0">{gettext("Status")}</div>
        </:head>
        <div
          :if={Enum.count(@streams.objects) > 0 or @page > 1}
          id="objects_list"
          phx-update="stream"
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
      </.list_table>
      <.infinite_scroll_footer ended={@end_of_timeline?} />
    </div>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(page_title: gettext("Recurring Listing"))

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    params = params["search"]

    terms = params["terms"] || ""

    {:noreply,
     socket
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

    url = "/companies/#{socket.assigns.current_company.id}/recurrings?#{URI.encode_query(qry)}"

    {:noreply, socket |> push_navigate(to: url)}
  end

  defp filter_objects(socket, terms, reset, page) when page >= 1 do
    query = HR.recurring_query(socket.assigns.current_company, socket.assigns.current_user)

    objects =
      StdInterface.filter(
        query,
        [:recur_no, :employee_name, :salary_type_name, :status],
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
