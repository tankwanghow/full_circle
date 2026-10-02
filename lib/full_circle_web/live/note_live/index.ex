defmodule FullCircleWeb.NoteLive.Index do
  @moduledoc """
  The notes feed: newest first, like a social timeline. A post box at the top
  does a quick-add (body, optional subject, who can read it); the note's own
  page (the edit page) is where a title, links and files are added.
  """
  use FullCircleWeb, :live_view

  import FullCircleWeb.NoteComponents

  alias FullCircle.{Linkable, Notes, Repo}

  @per_page 30

  @impl true
  def mount(_params, _session, socket) do
    %{current_user: user, current_company: com} = socket.assigns

    if FullCircle.Authorization.can?(user, :view_notes, com) do
      {:ok,
       socket
       |> assign(
         page_title: gettext("Notes"),
         can_create: FullCircle.Authorization.can?(user, :create_note, com),
         show_dates: false
       )}
    else
      {:ok,
       socket
       |> put_flash(:warn, gettext("Not Authorise."))
       |> push_navigate(to: ~p"/companies/#{com.id}/dashboard")}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    terms = get_in(params, ["search", "terms"]) || ""
    filters = Map.take(params["filters"] || %{}, ~w(subject_type mine from to))

    {:noreply,
     socket
     |> assign(search: %{terms: terms}, filters: filters)
     |> load(1, true)}
  end

  # --- feed ------------------------------------------------------------------

  @impl true
  def handle_event("search", %{"search" => %{"terms" => terms}}, socket) do
    {:noreply, push_patch(socket, to: index_path(socket, terms, socket.assigns.filters))}
  end

  def handle_event("filter", %{"filters" => filters}, socket) do
    filters = Map.merge(socket.assigns.filters, filters)
    {:noreply, push_patch(socket, to: index_path(socket, socket.assigns.search.terms, filters))}
  end

  def handle_event("tab", %{"mine" => mine}, socket) do
    filters = Map.put(socket.assigns.filters, "mine", mine)
    {:noreply, push_patch(socket, to: index_path(socket, socket.assigns.search.terms, filters))}
  end

  def handle_event("toggle_dates", _, socket),
    do: {:noreply, assign(socket, show_dates: !socket.assigns.show_dates)}

  def handle_event("next-page", _, socket) do
    {:noreply, load(socket, socket.assigns.page + 1, false)}
  end

  # --- post box ----------------------------------------------------------------

  # The post box (ComposerComponent) saved a note: it goes on top of the feed.
  @impl true
  def handle_info({:composer, "compose", {:saved, :new, note}}, socket) do
    %{current_company: com, current_user: user} = socket.assigns
    note = Repo.preload(note, [:author, :attachments], force: true)

    {:noreply,
     socket
     |> stream_insert(:notes, feed_item(note, Notes.feed_details([note], com, user)), at: 0)
     |> assign(empty?: false)}
  end

  def handle_info({:composer, _id, _event}, socket), do: {:noreply, socket}

  # --- data ------------------------------------------------------------------

  # Not `url/3`: Phoenix.VerifiedRoutes imports a url macro of that arity.
  defp index_path(socket, terms, filters) do
    q =
      %{"search[terms]" => terms}
      |> Map.merge(Map.new(filters, fn {k, v} -> {"filters[#{k}]", v} end))
      |> URI.encode_query()

    "/companies/#{socket.assigns.current_company.id}/notes?#{q}"
  end

  defp load(socket, page, reset) do
    %{current_company: com, current_user: user} = socket.assigns

    notes =
      Notes.search(com, user, socket.assigns.search.terms, socket.assigns.filters,
        page: page,
        per_page: @per_page
      )
      |> Repo.preload(:attachments)

    details = Notes.feed_details(notes, com, user)

    socket
    |> assign(
      page: page,
      end_of_timeline?: length(notes) < @per_page,
      empty?: reset and notes == []
    )
    |> stream(:notes, Enum.map(notes, &feed_item(&1, details)), reset: reset)
  end

  defp feed_item(note, details), do: %{id: note.id, note: note, d: Map.fetch!(details, note.id)}

  # --- render ----------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-xl border-x border-gray-200 bg-white dark:border-gray-700 dark:bg-gray-900">
      <div class="flex border-b border-gray-200 dark:border-gray-700">
        <button
          :for={
            {mine, label} <- [{"false", gettext("All notes")}, {"true", gettext("Written by me")}]
          }
          id={if mine == "true", do: "tab-mine", else: "tab-all"}
          type="button"
          phx-click="tab"
          phx-value-mine={mine}
          class={[
            "flex-1 py-3 text-sm font-bold hover:bg-gray-50 dark:hover:bg-gray-800",
            if((@filters["mine"] || "false") == mine,
              do: "text-gray-900 shadow-[inset_0_-3px_0_#1d9bf0] dark:text-gray-100",
              else: "text-gray-500"
            )
          ]}
        >
          {label}
        </button>
      </div>

      <div :if={@can_create} class="border-b border-gray-200 px-4 py-3 dark:border-gray-700">
        <.live_component
          module={FullCircleWeb.NoteLive.ComposerComponent}
          id="compose"
          avatar
          full_form_path={~p"/companies/#{@current_company.id}/notes/new"}
          current_company={@current_company}
          current_user={@current_user}
        />
      </div>

      <div class="border-b border-gray-200 px-4 py-2 dark:border-gray-700">
        <div class="flex items-center gap-2">
          <form id="search-form" phx-change="search" phx-submit="search" class="flex-1">
            <input
              type="search"
              name="search[terms]"
              value={@search.terms}
              phx-debounce="300"
              autocomplete="off"
              placeholder={"🔍 " <> gettext("Search notes")}
              class="w-full rounded-full border-0 bg-gray-100 px-4 py-1.5 text-sm focus:ring-1 focus:ring-sky-400 dark:bg-gray-800"
            />
          </form>
          <form id="filter-form" phx-change="filter">
            <select
              name="filters[subject_type]"
              class="rounded-full border-gray-300 py-1 text-xs dark:border-gray-600 dark:bg-gray-800"
            >
              <option value="">{gettext("About: anything")}</option>
              <option :for={t <- Linkable.types()} value={t} selected={@filters["subject_type"] == t}>
                {type_label(t)}
              </option>
            </select>
          </form>
          <button
            type="button"
            phx-click="toggle_dates"
            class={[
              "rounded-full border px-2 py-1 text-xs",
              if(@filters["from"] not in [nil, ""] or @filters["to"] not in [nil, ""],
                do: "border-sky-400 bg-sky-100 dark:bg-sky-900",
                else: "border-gray-300 dark:border-gray-600"
              )
            ]}
            title={gettext("Dates")}
          >
            📅
          </button>
        </div>
        <form
          :if={@show_dates}
          id="date-form"
          phx-change="filter"
          class="mt-2 flex items-center gap-2 text-xs"
        >
          {gettext("From")}
          <input
            type="date"
            name="filters[from]"
            value={@filters["from"]}
            class="rounded border-gray-300 py-0.5 text-xs dark:border-gray-600 dark:bg-gray-800"
          />
          {gettext("To")}
          <input
            type="date"
            name="filters[to]"
            value={@filters["to"]}
            class="rounded border-gray-300 py-0.5 text-xs dark:border-gray-600 dark:bg-gray-800"
          />
        </form>
      </div>

      <div id="notes" phx-update="stream">
        <.note_post
          :for={{dom_id, item} <- @streams.notes}
          id={dom_id}
          item={item}
          current_company={@current_company}
        />
      </div>
      <p :if={@empty?} class="px-4 py-8 text-center text-gray-500">
        {gettext("No notes yet.")}
      </p>
      <.infinite_scroll_footer ended={@end_of_timeline?} />
    </div>
    """
  end
end
