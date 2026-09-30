defmodule FullCircleWeb.NoteLive.Index do
  @moduledoc """
  The notes feed: newest first, like a social timeline. A post box at the top
  does a quick-add (body, optional subject, who can read it); the note's own
  page (the edit page) is where a title, links and files are added.
  """
  use FullCircleWeb, :live_view

  import FullCircleWeb.NoteComponents

  alias FullCircle.{Linkable, Notes, Repo}
  alias FullCircle.Notes.Note
  alias FullCircleWeb.NoteLive.RecordPickerComponent

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
         compose_subject: nil,
         compose_picker: false,
         compose_roles: false,
         show_dates: false
       )
       |> reset_compose()}
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

  def handle_event("compose_validate", %{"note" => params}, socket),
    do: {:noreply, compose_change(socket, params)}

  # The post box's Everyone / Private chips (visibility_chips/1).
  def handle_event("visibility_everyone", _, socket),
    do:
      {:noreply,
       compose_change(socket, Map.put(socket.assigns.compose_params, "visibility", [""]))}

  def handle_event("visibility_private", _, socket) do
    params = Map.put(socket.assigns.compose_params, "visibility", Note.private_visibility())
    {:noreply, compose_change(socket, params)}
  end

  def handle_event("compose_toggle_roles", _, socket),
    do: {:noreply, assign(socket, compose_roles: !socket.assigns.compose_roles)}

  def handle_event("compose_toggle_picker", _, socket),
    do: {:noreply, assign(socket, compose_picker: !socket.assigns.compose_picker)}

  def handle_event("compose_clear_subject", _, socket),
    do: {:noreply, assign(socket, compose_subject: nil)}

  def handle_event("compose_post", %{"note" => params}, socket) do
    %{current_company: com, current_user: user, compose_subject: subject} = socket.assigns

    params =
      if subject,
        do: Map.merge(params, %{"subject_type" => subject.type, "subject_id" => subject.id}),
        else: params

    case Notes.create_note(params, com, user) do
      {:ok, note} ->
        note = Repo.preload(note, [:author, :attachments], force: true)

        {:noreply,
         socket
         |> stream_insert(:notes, feed_item(note, Notes.feed_details([note], com, user)), at: 0)
         |> assign(compose_subject: nil, compose_roles: false, empty?: false)
         |> reset_compose()}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, assign(socket, compose_form: compose_form(cs))}

      _ ->
        {:noreply, put_flash(socket, :warn, gettext("Not Authorise."))}
    end
  end

  @impl true
  def handle_info({:record_picked, "compose-picker", picked}, socket) do
    {:noreply, assign(socket, compose_subject: picked, compose_picker: false)}
  end

  # The box has its own input ids: two note forms on one page must not share
  # note_body. `compose_rev` also forces a fresh textarea after a post, which
  # clears it even though the browser still holds what was typed.
  defp reset_compose(socket) do
    rev = (socket.assigns[:compose_rev] || 0) + 1

    assign(socket,
      compose_rev: rev,
      compose_params: %{},
      compose_form: compose_form(Notes.change_note(%Note{}))
    )
  end

  defp compose_form(cs), do: to_form(cs, id: "compose_note")

  defp compose_change(socket, params) do
    cs = %Note{} |> Notes.change_note(params) |> Map.put(:action, :validate)
    assign(socket, compose_form: compose_form(cs), compose_params: params)
  end

  defp compose_roles(form), do: Ecto.Changeset.get_field(form.source, :visibility) || []

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

      <div
        :if={@can_create}
        class="flex gap-3 border-b border-gray-200 px-4 py-3 dark:border-gray-700"
      >
        <.avatar email={@current_user.email} />
        <div class="min-w-0 flex-1">
          <.form
            for={@compose_form}
            id="compose-form"
            phx-change="compose_validate"
            phx-submit="compose_post"
          >
            <textarea
              id={"compose_note_body_#{@compose_rev}"}
              name="note[body]"
              rows="2"
              placeholder={gettext("Write a note…")}
              class="w-full resize-y border-0 bg-transparent p-1 text-lg placeholder-gray-500 focus:ring-0"
            >{Phoenix.HTML.Form.normalize_value("textarea", @compose_form[:body].value)}</textarea>
            <.error :for={
              msg <-
                Enum.map(
                  @compose_form[:body].errors ++ @compose_form[:subject_id].errors,
                  &translate_error/1
                )
            }>
              {msg}
            </.error>

            <div :if={@compose_roles} class="flex flex-wrap gap-1 pb-2">
              <.visibility_chips
                visibility={compose_roles(@compose_form)}
                id_prefix="compose-visibility"
              />
            </div>
            <%!-- keep the chosen roles when the chips are folded away --%>
            <div :if={!@compose_roles}>
              <input type="hidden" name="note[visibility][]" value="" />
              <input
                :for={role <- compose_roles(@compose_form)}
                type="hidden"
                name="note[visibility][]"
                value={role}
              />
            </div>

            <div class="flex flex-wrap items-center gap-1 border-t border-gray-200 pt-2 dark:border-gray-700">
              <.record_chip
                :if={@compose_subject}
                target={{:ok, %{title: @compose_subject.title, url: nil}}}
                type={@compose_subject.type}
                kind={:subject}
              />
              <button
                :if={@compose_subject}
                type="button"
                phx-click="compose_clear_subject"
                class="text-xs text-gray-500"
                title={gettext("Clear")}
              >
                ✕
              </button>
              <button
                :if={!@compose_subject}
                id="compose-about"
                type="button"
                phx-click="compose_toggle_picker"
                class="rounded-full border border-amber-400 bg-amber-50 px-2 text-xs text-amber-900 dark:border-amber-600 dark:bg-amber-950 dark:text-amber-100"
              >
                ＋ {gettext("about…")}
              </button>
              <button
                type="button"
                phx-click="compose_toggle_roles"
                class="rounded-full border border-gray-300 px-2 text-xs text-gray-600 dark:border-gray-600 dark:text-gray-300"
              >
                <%= cond do %>
                  <% compose_roles(@compose_form) == [] -> %>
                    👥 {gettext("Everyone")} ▾
                  <% compose_roles(@compose_form) == Note.private_visibility() -> %>
                    🔒 {gettext("Private")} ▾
                  <% true -> %>
                    🔒 {Enum.join(compose_roles(@compose_form), ", ")} ▾
                <% end %>
              </button>
              <.link
                navigate={~p"/companies/#{@current_company.id}/notes/new"}
                class="ml-auto text-xs text-gray-500 hover:underline"
              >
                {gettext("Full form")}
              </.link>
              <button
                type="submit"
                class="rounded-full bg-sky-500 px-4 py-1 text-sm font-bold text-white hover:bg-sky-600"
              >
                {gettext("Post")}
              </button>
            </div>
          </.form>
          <div :if={@compose_picker} class="mt-2">
            <.live_component
              module={RecordPickerComponent}
              id="compose-picker"
              label={gettext("What is this note about?")}
              current_company={@current_company}
              current_user={@current_user}
            />
          </div>
        </div>
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

      <div id="notes" phx-update="stream" phx-viewport-bottom={!@end_of_timeline? && "next-page"}>
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
