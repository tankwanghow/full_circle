defmodule FullCircleWeb.HolidayLive.Index do
  use FullCircleWeb, :live_view

  alias FullCircleWeb.HolidayLive.IndexComponent
  alias FullCircle.HR.Holiday
  alias FullCircle.StdInterface

  @per_page 25

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto w-6/12">
      <p class="w-full text-3xl text-center font-medium"><%= @page_title %></p>
      <.search_form search_val={@search.terms} placeholder={gettext("Name or Short Name...")} />
      <div class="text-center mb-2">
        <.link
          navigate={~p"/companies/#{@current_company.id}/holidays/new"}
          class="blue button"
          id="new_holiday"
        >
          <%= gettext("New holidays") %>
        </.link>
      </div>
      <div class="text-center mb-1">
        <div class="rounded bg-amber-200 border border-amber-500 font-bold p-2">
          <%= gettext("Holiday Information") %>
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
      |> assign(page_title: gettext("Holiday Listing"))

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
     |> filter_objects(
       socket.assigns.search.terms,
       false,
       socket.assigns.page + 1
     )}
  end

  @impl true
  def handle_event(
        "search",
        %{
          "search" => %{
            "terms" => terms
          }
        },
        socket
      ) do
    qry = %{
      "search[terms]" => terms
    }

    url = "/companies/#{socket.assigns.current_company.id}/holidays?#{URI.encode_query(qry)}"

    {:noreply, socket |> push_patch(to: url)}
  end

  defp filter_objects(socket, terms, reset, page) do
    objects =
      StdInterface.filter(
        Holiday,
        [:name, :short_name],
        terms,
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
