defmodule FullCircleWeb.SalaryTypeLive.Index do
  use FullCircleWeb, :live_view

  alias FullCircle.HR
  alias FullCircle.StdInterface
  alias FullCircleWeb.SalaryTypeLive.IndexComponent

  @per_page 30

  @impl true
  def render(assigns) do
    ~H"""
    <div class="w-5/12 mx-auto">
      <p class="w-full text-3xl text-center font-medium">{@page_title}</p>
      <.search_form
        search_val={@search.terms}
        placeholder={gettext("Name, Debit Account or Credit Account...")}
      />
      <div class="text-center mb-2">
        <.link
          navigate={~p"/companies/#{@current_company.id}/salary_types/new"}
          class="blue button"
          id="new_object"
        >
          {gettext("New Salary Type")}
        </.link>
      </div>
      <div class="text-center">
        <div class="bg-amber-200 border-y-2 border-amber-500 font-bold p-2">
          {gettext("Salary Type Information")}
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
            current_role={@current_role}
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
      |> assign(page_title: gettext("Salary Type Listing"))

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

    url = "/companies/#{socket.assigns.current_company.id}/salary_types?#{URI.encode_query(qry)}"

    {:noreply, socket |> push_navigate(to: url)}
  end

  defp filter_objects(socket, terms, reset, page) when page >= 1 do
    query = HR.salary_type_query(socket.assigns.current_company, socket.assigns.current_user)

    objects =
      StdInterface.filter(
        query,
        [:name, :type, :db_ac_name, :cr_ac_name],
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
