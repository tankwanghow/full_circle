defmodule FullCircleWeb.NoteLive.NotesPanelComponent do
  @moduledoc """
  Notes about, or linking to, one record. Rendered under a record's edit form
  and inside the index-page notes modal. Self-contained: all events target it.
  """
  use FullCircleWeb, :live_component

  import FullCircleWeb.NoteComponents

  alias FullCircle.Notes
  alias FullCircle.Notes.Note

  # The host form re-renders on every keystroke (phx-change="validate"), which
  # calls update/2 each time. Only (re)load when the record changes, or the
  # panel would query per keystroke and wipe a half-typed quick-add.
  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:notify_parent, fn -> false end)
      |> assign_new(:class, fn -> nil end)
      |> assign_new(:adding, fn -> false end)
      |> assign_new(:params, fn -> %{} end)

    key = {socket.assigns.record_type, socket.assigns.record_id}

    if socket.assigns[:loaded_for] == key do
      {:ok, socket}
    else
      {:ok,
       socket
       |> assign(
         loaded_for: key,
         adding: false,
         form: panel_form(socket, Notes.change_note(blank_note(socket)))
       )
       |> load()}
    end
  end

  # Input ids are prefixed with the component id: the panel can sit on a page
  # that has its own note form (the note page itself), and two `note_body`
  # inputs would make the browser patch and focus the wrong textarea.
  # On a task, Private means "the people who can see this task" (Notes'
  # task rule), which is what a progress note almost always wants.
  defp blank_note(%{assigns: %{record_type: "Task"}}),
    do: %Note{visibility: Note.private_visibility()}

  defp blank_note(_socket), do: %Note{}

  defp panel_form(socket, cs), do: to_form(cs, id: "#{socket.assigns.id}_note")

  defp panel_change(socket, params) do
    cs = blank_note(socket) |> Notes.change_note(params) |> Map.put(:action, :validate)
    assign(socket, form: panel_form(socket, cs), params: params)
  end

  defp load(socket) do
    %{record_type: t, record_id: id, current_company: com, current_user: user} = socket.assigns
    rows = Notes.notes_for_record(t, id, com, user)
    details = Notes.feed_details(Enum.map(rows, & &1.note), com, user)
    # Every row is already visible, so edit rights need no per-note query.
    rights = Notes.rights(com, user)

    items =
      for r <- rows do
        %{
          id: r.note.id,
          note: r.note,
          d: Map.fetch!(details, r.note.id),
          relation: r.relation,
          can_attach: Notes.may_edit?(r.note, user, rights)
        }
      end

    assign(socket, items: items, can_create: rights.create)
  end

  @impl true
  def handle_event("new", _, socket), do: {:noreply, assign(socket, adding: true)}
  def handle_event("cancel", _, socket), do: {:noreply, assign(socket, adding: false)}

  def handle_event("validate", %{"note" => params}, socket),
    do: {:noreply, panel_change(socket, params)}

  def handle_event("visibility_everyone", _, socket),
    do: {:noreply, panel_change(socket, Map.put(socket.assigns.params, "visibility", [""]))}

  def handle_event("visibility_private", _, socket) do
    params = Map.put(socket.assigns.params, "visibility", Note.private_visibility())
    {:noreply, panel_change(socket, params)}
  end

  def handle_event("save", %{"note" => params}, socket) do
    %{record_type: t, record_id: id, current_company: com, current_user: user} = socket.assigns
    attrs = Map.merge(params, %{"subject_type" => t, "subject_id" => id})

    case Notes.create_note(attrs, com, user) do
      {:ok, _note} ->
        if socket.assigns.notify_parent, do: send(self(), {:notes_changed, t, id})

        {:noreply,
         socket
         |> assign(
           adding: false,
           params: %{},
           form: panel_form(socket, Notes.change_note(blank_note(socket)))
         )
         |> load()}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, assign(socket, form: panel_form(socket, cs))}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("attachment_uploaded", _, socket), do: {:noreply, load(socket)}

  @impl true
  def render(assigns) do
    ~H"""
    <section
      id={@id}
      class={
        [
          "mx-auto mt-3 overflow-hidden rounded-xl border border-gray-200 bg-white dark:border-gray-700 dark:bg-gray-900",
          @class,
          # Posts are short text + a thumbnail row: a readable column, even under
          # a wide invoice card (w-11/12), keeps the eye from travelling.
          "max-w-2xl"
        ]
      }
    >
      <div class="flex items-center gap-2 border-b border-gray-200 px-4 py-2 dark:border-gray-700">
        <span class="font-semibold">📝 {gettext("Notes")}</span>
        <span class="text-sm text-gray-500">{length(@items)}</span>
        <.link
          :if={@can_create}
          navigate={"/companies/#{@current_company.id}/notes/new?subject_type=#{@record_type}&subject_id=#{@record_id}"}
          class="ml-auto text-xs text-gray-500 hover:underline dark:text-gray-400"
        >
          {gettext("Full form")}
        </.link>
        <button
          :if={@can_create and !@adding}
          id={"#{@id}-new"}
          type="button"
          phx-click="new"
          phx-target={@myself}
          class={[
            "rounded-full bg-sky-500 px-3 py-0.5 text-sm font-bold text-white hover:bg-sky-600",
            !@can_create && "ml-auto"
          ]}
        >
          ＋ {gettext("Note")}
        </button>
      </div>

      <.form
        :if={@adding}
        for={@form}
        id={"#{@id}-form"}
        phx-change="validate"
        phx-submit="save"
        phx-target={@myself}
        class="border-b border-gray-200 px-4 py-3 dark:border-gray-700"
      >
        <.input
          field={@form[:body]}
          type="textarea"
          rows="3"
          placeholder={gettext("Write a note…")}
        />
        <%!-- The subject is fixed to this record and has no input of its own;
             without this line a subject error would make Save silently do nothing. --%>
        <.error :for={
          msg <-
            Enum.map(
              @form[:subject_id].errors ++ @form[:subject_type].errors ++ @form[:visibility].errors,
              &translate_error/1
            )
        }>
          {msg}
        </.error>
        <div class="mt-2 flex flex-wrap items-center gap-1 text-xs">
          <.visibility_chips
            visibility={Ecto.Changeset.get_field(@form.source, :visibility)}
            id_prefix={"#{@id}-visibility"}
            target={@myself}
            roles={@record_type != "Task"}
            private_title={
              @record_type == "Task" &&
                gettext("Only the people who can see this task (and admins) can read it.")
            }
          />
          <span class="ml-auto flex items-center gap-2">
            <button
              type="button"
              phx-click="cancel"
              phx-target={@myself}
              class="text-sm text-gray-500 hover:underline"
            >
              {gettext("Cancel")}
            </button>
            <button
              type="submit"
              class="rounded-full bg-sky-500 px-4 py-1 text-sm font-bold text-white hover:bg-sky-600"
            >
              {gettext("Post")}
            </button>
          </span>
        </div>
        <p :if={@record_type == "Task"} class="mt-1 text-xs text-slate-500 dark:text-slate-400">
          {gettext("Everyone who can see this task can read its notes.")}
        </p>
      </.form>

      <.note_post
        :for={item <- @items}
        id={"#{@id}-note-#{item.id}"}
        item={item}
        current_company={@current_company}
        host={{@record_type, @record_id}}
        relation={item.relation}
        can_attach={item.can_attach}
        new_tab
        compact
      />
      <p :if={@items == []} class="px-4 py-3 text-sm text-gray-500">{gettext("No notes yet.")}</p>
    </section>
    """
  end
end
