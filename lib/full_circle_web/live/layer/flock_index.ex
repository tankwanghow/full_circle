defmodule FullCircleWeb.LayerLive.FlockIndex do
  use FullCircleWeb, :live_view

  import FullCircleWeb.ListComponents

  alias FullCircleWeb.LayerLive.FlockIndexComponent
  alias FullCircle.Layer.{Flock, Movement, House}
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
              placeholder="flock no, breed..."
            />
          </div>
          <div class="w-36">
            <.filter_label>{gettext("DOB From")}</.filter_label>
            <.input name="search[dob]" type="date" value={@search.dob} id="search_dob" />
          </div>
          <.button class="h-9 w-10">🔍</.button>
          <:actions>
            <.link
              navigate={~p"/companies/#{@current_company.id}/flocks/new"}
              class="blue button"
              id="new_flock"
            >
              + {gettext("New Flock")}
            </.link>
          </:actions>
        </.list_bar>
      </.form>

      <.list_table gap="gap-0">
        <:head>
          <div class="w-[10%] shrink-0 px-1">{gettext("DOB")}</div>
          <div class="w-[14%] shrink-0 px-1">{gettext("Flock No")}</div>
          <div class="w-[10%] shrink-0 px-1">{gettext("Breed")}</div>
          <div class="w-[10%] shrink-0 px-1 text-right tabular-nums">{gettext("Quantity")}</div>
          <div class="w-[31%] shrink-0 px-1">{gettext("Houses")}</div>
          <div class="w-[25%] shrink-0 px-1">{gettext("Note")}</div>
        </:head>
        <div
          :if={Enum.count(@streams.objects) > 0 or @page > 1}
          id="objects_list"
          phx-update="stream"
          phx-page-loading
        >
          <%= for {obj_id, obj} <- @streams.objects do %>
            <.live_component
              module={FlockIndexComponent}
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
      |> assign(page_title: gettext("Flock Listing"))

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    params = params["search"]
    terms = params["terms"] || ""
    dob = params["dob"] || ""

    {:noreply,
     socket
     |> assign(search: %{terms: terms, dob: dob})
     |> assign(can_print: false)
     |> filter_objects(terms, true, dob, 1)}
  end

  @impl true
  def handle_event("next-page", _, socket) do
    {:noreply,
     socket
     |> filter_objects(
       socket.assigns.search.terms,
       false,
       socket.assigns.search.dob,
       socket.assigns.page + 1
     )}
  end

  @impl true
  def handle_event(
        "search",
        %{
          "search" => %{
            "terms" => terms,
            "dob" => id
          }
        },
        socket
      ) do
    qry = %{
      "search[terms]" => terms,
      "search[dob]" => id
    }

    url = "/companies/#{socket.assigns.current_company.id}/flocks?#{URI.encode_query(qry)}"

    {:noreply, socket |> push_navigate(to: url)}
  end

  import Ecto.Query, warn: false

  defp filter_objects(socket, terms, reset, "", page) do
    from(obj in Flock,
      join: mv in Movement,
      on: mv.flock_id == obj.id,
      join: h in House,
      on: h.id == mv.house_id,
      join:
        com in subquery(
          FullCircle.Sys.user_company(
            socket.assigns.current_company,
            socket.assigns.current_user
          )
        ),
      on: com.id == obj.company_id,
      select: obj,
      select_merge: %{
        houses: fragment("string_agg(distinct ?, ', ')", h.house_no)
      },
      group_by: obj.id,
      order_by: [desc: obj.dob]
    )
    |> filter(socket, terms, reset, page)
  end

  defp filter_objects(socket, terms, reset, dob, page) do
    from(obj in Flock,
      join: mv in Movement,
      on: mv.flock_id == obj.id,
      join: h in House,
      on: h.id == mv.house_id,
      join:
        com in subquery(
          FullCircle.Sys.user_company(
            socket.assigns.current_company,
            socket.assigns.current_user
          )
        ),
      on: com.id == obj.company_id,
      where: obj.dob >= ^dob,
      select: obj,
      select_merge: %{
        houses: fragment("string_agg(distinct ?, ', ')", h.house_no)
      },
      group_by: obj.id,
      order_by: [desc: obj.dob]
    )
    |> filter(socket, terms, reset, page)
  end

  defp filter(qry, socket, terms, reset, page) do
    objects =
      StdInterface.filter(
        qry,
        [:flock_no, :breed, :note],
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
