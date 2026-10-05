defmodule FullCircleWeb.ContactLive.Index do
  use FullCircleWeb, :live_view

  import FullCircleWeb.ListComponents

  alias FullCircle.StdInterface
  alias FullCircle.Accounting.Contact
  alias FullCircleWeb.ContactLive.IndexComponent
  alias FullCircleWeb.NoteLive.NotesIndex

  @per_page 30

  @impl true
  def render(assigns) do
    ~H"""
    <div class="w-11/12 max-w-6xl mx-auto">
      <.list_bar title={@page_title}>
        <.search_form
          compact
          live
          search_val={@search.terms}
          placeholder={gettext("Name, City, State, Email, Phone and Descriptions...")}
        />
        <:actions>
          <.link navigate={~p"/companies/#{@current_company.id}/contacts/new"} class="blue button">
            + {gettext("New Contact")}
          </.link>
        </:actions>
      </.list_bar>

      <.list_table>
        <:head>
          <div class="w-[24%] shrink-0">{gettext("Name")}</div>
          <div class="w-[11%] shrink-0">{gettext("Category")}</div>
          <div class="flex-1 min-w-0">{gettext("Address")}</div>
          <div class="w-[12%] shrink-0">{gettext("Phone")}</div>
          <div class="w-[16%] shrink-0">{gettext("Email")}</div>
          <div class="w-[14%] shrink-0">{gettext("Descriptions")}</div>
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
      |> assign(page_title: gettext("Contacts Listing"))
      |> NotesIndex.init("Contact", IndexComponent)

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

    url = "/companies/#{socket.assigns.current_company.id}/contacts?#{URI.encode_query(qry)}"

    {:noreply, socket |> push_patch(to: url)}
  end

  defp filter_objects(socket, terms, reset, page) do
    objects =
      StdInterface.filter(
        Contact,
        [:name, :category, :city, :state, :email, :phone, :descriptions],
        terms,
        socket.assigns.current_company,
        socket.assigns.current_user,
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
