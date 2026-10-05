defmodule FullCircleWeb.JournalLive.Index do
  use FullCircleWeb, :live_view

  import FullCircleWeb.ListComponents

  alias FullCircle.JournalEntry
  alias FullCircleWeb.JournalLive.IndexComponent
  alias FullCircleWeb.NoteLive.NotesIndex

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
              placeholder="journal, contact, accounts or descriptions..."
            />
          </div>
          <div class="w-36">
            <.filter_label>{gettext("Journal Date")}</.filter_label>
            <.input
              name="search[journal_date]"
              type="date"
              value={@search.journal_date}
              id="search_journal_date"
            />
          </div>
          <.button class="h-9 w-10">🔍</.button>
          <:actions>
            <.link
              :if={@can_print}
              navigate={
                ~p"/companies/#{@current_company.id}/Journal/print_multi?pre_print=false&ids=#{@ids}"
              }
              target="_blank"
              class="blue button"
            >
              {gettext("Print")}{"(#{Enum.count(@selected)})"}
            </.link>
            <.link
              :if={@can_print}
              navigate={
                ~p"/companies/#{@current_company.id}/Journal/print_multi?pre_print=true&ids=#{@ids}"
              }
              target="_blank"
              class="blue button"
            >
              {gettext("Pre Print")}{"(#{Enum.count(@selected)})"}
            </.link>
            <.link
              navigate={~p"/companies/#{@current_company.id}/Journal/new"}
              class="blue button"
              id="new_journal"
            >
              + {gettext("New Journal")}
            </.link>
          </:actions>
        </.list_bar>
      </.form>

      <.list_table gap="gap-0">
        <:head>
          <div class="w-6 shrink-0 text-center"></div>
          <div class="w-[9%] shrink-0 px-1">{gettext("Date")}</div>
          <div class="w-[9%] shrink-0 px-1">{gettext("Journal No")}</div>
          <div class="w-[40%] shrink-0 px-1">{gettext("Account Info")}</div>
          <div class="w-[40%] shrink-0 px-1">{gettext("Particulars Info")}</div>
        </:head>
        <div
          id="objects_list"
          phx-update="stream"
          phx-page-loading
        >
          <%= for {obj_id, obj} <- @streams.objects do %>
            <.live_component
              module={IndexComponent}
              note_count={Map.get(@note_counts, obj.id, 0)}
              task_count={Map.get(@task_counts, obj.id, 0)}
              id={
                if(obj_id == "objects-",
                  do: "objects-#{FullCircle.Helpers.gen_temp_id(10)}",
                  else: obj_id
                )
              }
              obj={obj}
              company={@current_company}
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
      |> assign(page_title: gettext("Journal Listing"))
      |> NotesIndex.init("Journal", IndexComponent)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    params = params["search"]

    terms = params["terms"] || ""
    journal_date = params["journal_date"] || ""

    {:noreply,
     socket
     |> assign(
       search: %{
         terms: terms,
         journal_date: journal_date
       }
     )
     |> assign(selected: [])
     |> assign(ids: "")
     |> assign(can_print: false)
     |> filter_objects(terms, true, journal_date, 1)}
  end

  @impl true
  def handle_event("check_click", %{"object-id" => id, "value" => "on"}, socket) do
    obj =
      FullCircle.JournalEntry.get_journal_by_id_index_component_field!(
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
      FullCircle.JournalEntry.get_journal_by_id_index_component_field!(
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
       socket.assigns.search.journal_date,
       socket.assigns.page + 1
     )}
  end

  @impl true
  def handle_event(
        "search",
        %{
          "search" => %{
            "terms" => terms,
            "journal_date" => id
          }
        },
        socket
      ) do
    qry = %{
      "search[terms]" => terms,
      "search[journal_date]" => id
    }

    url = "/companies/#{socket.assigns.current_company.id}/Journal?#{URI.encode_query(qry)}"

    {:noreply, socket |> push_navigate(to: url)}
  end

  defp filter_objects(socket, terms, reset, journal_date, page) do
    objects =
      JournalEntry.journal_index_query(
        terms,
        journal_date,
        socket.assigns.current_company,
        socket.assigns.current_user,
        page: page,
        per_page: @per_page
      )

    obj_count = Enum.count(objects)

    socket
    |> assign(page: page, per_page: @per_page)
    |> NotesIndex.count(objects, reset)
    |> stream(:objects, objects, reset: reset)
    |> assign(end_of_timeline?: obj_count < @per_page)
  end
end
