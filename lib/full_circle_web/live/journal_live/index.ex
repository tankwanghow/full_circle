defmodule FullCircleWeb.JournalLive.Index do
  use FullCircleWeb, :live_view

  alias FullCircle.JournalEntry
  alias FullCircleWeb.JournalLive.IndexComponent

  @per_page 25

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto w-10/12">
      <p class="w-full text-3xl text-center font-medium"><%= @page_title %></p>
      <div class="flex justify-center mb-2">
        <.form for={%{}} id="search-form" phx-submit="search" class="w-full" autocomplete="off">
          <div class=" flex flex-row flex-wrap tracking-tighter text-sm">
            <div class="w-[25rem] grow shrink">
              <label class="">Search Terms</label>
              <.input
                id="search_terms"
                name="search[terms]"
                type="search"
                value={@search.terms}
                placeholder="journal, contact, accounts or descriptions..."
              />
            </div>
            <div class="w-[9.5rem] grow-0 shrink-0">
              <label>Journal Date</label>
              <.input
                name="search[journal_date]"
                type="date"
                value={@search.journal_date}
                id="search_journal_date"
              />
            </div>
            <.button class="mt-5 h-10 w-10 grow-0 shrink-0">🔍</.button>
          </div>
        </.form>
      </div>
      <div class="text-center mb-2">
        <.link
          navigate={~p"/companies/#{@current_company.id}/Journal/new"}
          class="blue_button"
          id="new_journal"
        >
          <%= gettext("New Journal") %>
        </.link>
      </div>

      <div class="font-medium flex flex-row text-center tracking-tighter bg-amber-200">
        <div class="w-[2%] border-b border-t border-amber-400 py-1"></div>
        <div class="w-[9%] border-b border-t border-amber-400 py-1">
          <%= gettext("Date") %>
        </div>
        <div class="w-[9%] border-b border-t border-amber-400 py-1">
          <%= gettext("Journal No") %>
        </div>
        <div class="w-[40%] border-b border-t border-amber-400 py-1">
          <%= gettext("Account Info") %>
        </div>
        <div class="w-[40%] border-b border-t border-amber-400 py-1">
          <%= gettext("Particulars Info") %>
        </div>
      </div>
      <div
        :if={Enum.count(@streams.objects) > 0 or @page > 1}
        id="objects_list"
        phx-update={@update}
        phx-viewport-bottom={!@end_of_timeline? && "next-page"}
        phx-page-loading
      >
        <%= for {obj_id, obj} <- @streams.objects do %>
          <.live_component
            module={IndexComponent}
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
      <.infinite_scroll_footer ended={@end_of_timeline?} />
    </div>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(page_title: gettext("Journal Listing"))

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
     |> assign(selected_journals: [])
     |> assign(ids: "")
     |> filter_objects(terms, "replace", journal_date, 1)}
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
      |> assign(selected_journals: [id | socket.assigns.selected_journals])

    {:noreply, socket |> assign(ids: Enum.join(socket.assigns.selected_journals, ","))}
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
      |> assign(
        selected_journals: Enum.reject(socket.assigns.selected_journals, fn sid -> sid == id end)
      )

    {:noreply, socket |> assign(ids: Enum.join(socket.assigns.selected_journals, ","))}
  end

  @impl true
  def handle_event("next-page", _, socket) do
    {:noreply,
     socket
     |> filter_objects(
       socket.assigns.search.terms,
       "stream",
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

    {:noreply, socket |> push_patch(to: url)}
  end

  defp filter_objects(socket, terms, update, journal_date, page) do
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
    |> assign(update: update)
    |> stream(:objects, objects, reset: obj_count == 0)
    |> assign(end_of_timeline?: obj_count < @per_page)
  end
end