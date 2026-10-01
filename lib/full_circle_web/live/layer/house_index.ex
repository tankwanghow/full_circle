defmodule FullCircleWeb.LayerLive.HouseIndex do
  alias FullCircleWeb.LayerLive.HouseIndexComponent
  use FullCircleWeb, :live_view

  import FullCircleWeb.ListComponents

  @per_page 50

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto w-6/12">
      <.form for={%{}} id="search-form" phx-submit="search" autocomplete="off">
        <.list_bar title={@page_title}>
          <div class="grow min-w-56">
            <.filter_label>{gettext("Search Terms")}</.filter_label>
            <.input
              id="search_terms"
              name="search[terms]"
              type="search"
              value={@search.terms}
              placeholder="house, flock..."
            />
          </div>
          <.button class="h-9 w-10">🔍</.button>
          <:actions>
            <.link
              navigate={~p"/companies/#{@current_company.id}/houses/new"}
              class="blue button"
              id="new_house"
            >
              + {gettext("New House")}
            </.link>
          </:actions>
        </.list_bar>
      </.form>

      <.list_table gap="gap-0">
        <:head>
          <div class="w-[14%] shrink-0 px-1">{gettext("House No")}</div>
          <div class="w-[14%] shrink-0 px-1">{gettext("Capacity")}</div>
          <div class="w-[15%] shrink-0 px-1">{gettext("Flock")}</div>
          <div class="w-[15%] shrink-0 px-1">{gettext("Quantity")}</div>
          <div class="w-[14%] shrink-0 px-1">{gettext("Filling")}</div>
          <div class="w-[14%] shrink-0 px-1">{gettext("Feeding")}</div>
          <div class="w-[14%] shrink-0 px-1">{gettext("Status")}</div>
        </:head>
        <div
          :if={Enum.count(@streams.objects) > 0 or @page > 1}
          id="objects_list"
          phx-update="stream"
          phx-page-loading
        >
          <%= for {obj_id, obj} <- @streams.objects do %>
            <.live_component
              module={HouseIndexComponent}
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
    {:ok, socket |> assign(page_title: gettext("House Listing"))}
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

    url = "/companies/#{socket.assigns.current_company.id}/houses?#{URI.encode_query(qry)}"

    {:noreply, socket |> push_navigate(to: url)}
  end

  defp filter_objects(socket, terms, reset, page) do
    objects =
      FullCircle.Layer.house_index(terms, socket.assigns.current_company.id,
        page: page,
        per_page: @per_page
      )

    socket
    |> assign(page: page, per_page: @per_page)
    |> stream(:objects, objects, reset: reset)
    |> assign(end_of_timeline?: Enum.count(objects) < @per_page)
  end
end
