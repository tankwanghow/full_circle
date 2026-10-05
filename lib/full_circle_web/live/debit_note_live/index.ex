defmodule FullCircleWeb.DebitNoteLive.Index do
  use FullCircleWeb, :live_view

  import FullCircleWeb.ListComponents

  alias FullCircle.DebCre
  alias FullCircleWeb.DebitNoteLive.IndexComponent
  alias FullCircleWeb.NoteLive.NotesIndex

  @per_page 25
  @selected_max 15

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto w-11/12 max-w-[96rem]">
      <.form for={%{}} id="search-form" phx-submit="search" autocomplete="off">
        <.list_bar title={@page_title}>
          <div class="grow min-w-56">
            <.filter_label>{gettext("Search Terms")}</.filter_label>
            <.input
              id="search_terms"
              name="search[terms]"
              type="search"
              value={@search.terms}
              placeholder="debit note, contact or account..."
            />
          </div>
          <div class="w-36">
            <.filter_label>{gettext("Debit Note Date From")}</.filter_label>
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
                ~p"/companies/#{@current_company.id}/CreditNote/print_multi?pre_print=false&ids=#{@ids}"
              }
              target="_blank"
              class="blue button"
            >
              {gettext("Print")}{"(#{Enum.count(@selected)})"}
            </.link>
            <.link
              :if={@can_print}
              navigate={
                ~p"/companies/#{@current_company.id}/CreditNote/print_multi?pre_print=true&ids=#{@ids}"
              }
              target="_blank"
              class="blue button"
            >
              {gettext("Pre Print")}{"(#{Enum.count(@selected)})"}
            </.link>
            <.link
              navigate={~p"/companies/#{@current_company.id}/DebitNote/new"}
              class="blue button"
              id="new_object"
            >
              + {gettext("New Debit Note")}
            </.link>
          </:actions>
        </.list_bar>
      </.form>

      <.list_table>
        <:head>
          <div class="w-6 shrink-0"></div>
          <div class="w-24 shrink-0">{gettext("Date")}</div>
          <div class="w-40 shrink-0">{gettext("No.")}</div>
          <div class="flex-1 min-w-0">{gettext("Contact")}</div>
          <div class="w-[24%] shrink-0">{gettext("Particulars")}</div>
          <div class="w-28 shrink-0 text-right">{gettext("Amount")}</div>
          <div class="w-36 shrink-0">{gettext("e-Invoice")}</div>
          <div class="w-6 shrink-0"></div>
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
              id={obj_id}
              obj={obj}
              company={@current_company}
              user={@current_user}
              einv_portal={@einv_portal}
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
      |> assign(page_title: gettext("Debit Note Listing"))
      |> NotesIndex.init("DebitNote", IndexComponent)

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
      DebCre.get_debit_note_by_id_index_component_field!(
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
      DebCre.get_debit_note_by_id_index_component_field!(
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

    url = "/companies/#{socket.assigns.current_company.id}/DebitNote?#{URI.encode_query(qry)}"

    {:noreply, socket |> push_navigate(to: url)}
  end

  defp filter_objects(socket, terms, reset, note_date, page) do
    objects =
      DebCre.debit_note_index_query(
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
    |> NotesIndex.count(objects, reset)
    |> stream(:objects, objects, reset: reset)
    |> assign(end_of_timeline?: obj_count < @per_page)
  end
end
