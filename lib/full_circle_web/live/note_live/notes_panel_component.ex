defmodule FullCircleWeb.NoteLive.NotesPanelComponent do
  @moduledoc """
  Notes about, or linking to, one record. Rendered under a record's edit form
  and inside the index-page notes modal. Self-contained: all events target it.
  """
  use FullCircleWeb, :live_component

  import FullCircleWeb.NoteComponents

  alias FullCircle.Notes
  alias FullCircle.Notes.Attachments
  alias FullCircleWeb.NoteLive.{ComposerComponent, PhoneQrComponent}

  # The panel shows the newest @page notes; "Show older" adds @page more.
  @page 20

  # A composer finished: the quick-add box (`id`) or a note edited in place
  # (`id-edit`). Links on a saved note apply at once, so any edit reloads.
  # A file landed on one of the shown notes (FullCircleWeb.NoteFiles).
  @impl true
  def update(%{note_files: {:note, _}}, socket), do: {:ok, load(socket)}

  def update(%{composer: {cid, event}}, socket) do
    editor? = cid == edit_id(socket.assigns.id)

    case event do
      {:saved, _mode, _note} ->
        notify_parent(socket)
        {:ok, socket |> stop(editor?) |> load()}

      :cancelled ->
        {:ok, if(editor?, do: socket |> stop(true) |> load(), else: stop(socket, false))}
    end
  end

  # The host form re-renders on every keystroke (phx-change="validate"), which
  # calls update/2 each time. Only (re)load when the record changes, or the
  # panel would query per keystroke.
  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:notify_parent, fn -> false end)
      |> assign_new(:class, fn -> nil end)
      |> assign_new(:flush, fn -> false end)
      |> assign_new(:adding, fn -> false end)
      |> assign_new(:edit_note, fn -> nil end)
      |> assign_new(:heading, fn -> nil end)
      |> assign_new(:limit, fn -> @page end)

    key = {socket.assigns.record_type, socket.assigns.record_id}

    if socket.assigns[:loaded_for] == key do
      {:ok, socket}
    else
      {:ok, socket |> assign(loaded_for: key, adding: false, limit: @page) |> load()}
    end
  end

  defp load(socket) do
    %{record_type: t, record_id: id, current_company: com, current_user: user} = socket.assigns
    rows = Notes.notes_for_record(t, id, com, user, limit: socket.assigns.limit)
    total = Notes.count_by_records(com, user, t, [id]) |> Map.get(id, 0)
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

    for item <- items,
        do: FullCircleWeb.NoteFiles.listen({:note, item.id}, __MODULE__, socket.assigns.id)

    assign(socket, items: items, total: max(total, length(items)), can_create: rights.create)
  end

  defp edit_id(id), do: "#{id}-edit"

  defp stop(socket, true = _editor?), do: assign(socket, edit_note: nil)
  defp stop(socket, false), do: assign(socket, adding: false)

  defp notify_parent(%{assigns: %{notify_parent: true, record_type: t, record_id: id}}),
    do: send(self(), {:notes_changed, t, id})

  defp notify_parent(_socket), do: :ok

  @impl true
  def handle_event("new", _, socket), do: {:noreply, assign(socket, adding: true)}
  def handle_event("cancel", _, socket), do: {:noreply, assign(socket, adding: false)}

  def handle_event("older", _, socket),
    do: {:noreply, socket |> assign(limit: socket.assigns.limit + @page) |> load()}

  def handle_event("attachment_uploaded", _, socket), do: {:noreply, load(socket)}

  # The box edits the note as it was when Edit was pressed: a later reload (a
  # file just uploaded) must not hand it a newer lock_version, or a save would
  # overwrite someone else's edit instead of coming back stale.
  def handle_event("edit_note", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.items, &(&1.id == id and &1.can_attach)) do
      nil -> {:noreply, socket}
      item -> {:noreply, assign(socket, edit_note: item.note)}
    end
  end

  def handle_event("remove_attachment", %{"id" => id}, socket) do
    %{items: items, current_company: com, current_user: user} = socket.assigns

    att =
      for(i <- items, i.can_attach, a <- i.note.attachments, a.id == id, do: a)
      |> List.first()

    if att, do: Attachments.remove(att, com, user)
    {:noreply, load(socket)}
  end

  # A note about this record keeps it: no chip to clear, as the post shows none.
  # A note that only links here keeps its own subject, editable as anywhere.
  defp host_subject(%{subject_type: t, subject_id: id}, t, id), do: {t, id}
  defp host_subject(_note, _type, _id), do: nil

  defp editing?(%{id: id}, %{id: id}), do: true
  defp editing?(_item, _edit_note), do: false

  # On a task its notes read as "Progress" (UI wording only; they are Notes).
  defp label("Task", :heading), do: gettext("Progress")
  defp label("Task", :add), do: gettext("Progress")
  defp label("Task", :empty), do: gettext("No progress yet.")
  defp label("Task", :placeholder), do: gettext("Write progress…")
  defp label(_type, :heading), do: gettext("Notes")
  defp label(_type, :add), do: gettext("Note")
  defp label(_type, :empty), do: gettext("No notes yet.")
  defp label(_type, :placeholder), do: nil

  @impl true
  def render(assigns) do
    ~H"""
    <%!-- flush: a section of a page whose neighbours already draw the lines
         (the task page), not a card beside a form. --%>
    <section
      id={@id}
      class={[
        "overflow-hidden border-gray-200 bg-white dark:border-gray-700 dark:bg-gray-900",
        !@flush && "rounded-xl border",
        @class
      ]}
    >
      <div class="flex items-center gap-2 border-b border-gray-200 px-4 py-2 dark:border-gray-700">
        <span class="font-semibold">{@heading || "📝 #{label(@record_type, :heading)}"}</span>
        <span class="text-sm text-gray-500">{@total}</span>
        <button
          :if={@can_create and !@adding}
          id={"#{@id}-new"}
          type="button"
          phx-click="new"
          phx-target={@myself}
          class="ml-auto rounded-full bg-sky-500 px-3 py-0.5 text-sm font-bold text-white hover:bg-sky-600"
        >
          ＋ {label(@record_type, :add)}
        </button>
      </div>

      <%!-- ＋ Note opens the full write box here (title, links), so the panel
           needs no "Full form" link to /notes/new. Files attach after saving. --%>
      <div
        :if={@adding and @can_create}
        class="border-b border-gray-200 px-4 py-3 dark:border-gray-700"
      >
        <.live_component
          module={FullCircleWeb.NoteLive.ComposerComponent}
          id={@id}
          placeholder={label(@record_type, :placeholder)}
          notify={{__MODULE__, @id}}
          full
          avatar
          fixed_subject={{@record_type, @record_id}}
          roles_open={@record_type != "Task"}
          roles={@record_type != "Task"}
          cancellable
          current_company={@current_company}
          current_user={@current_user}
        />
      </div>

      <%= for item <- @items do %>
        <%!-- Edit in place, laid out like the post it replaces (layout :post). --%>
        <div
          :if={editing?(item, @edit_note)}
          id={"#{@id}-editing"}
          class="border-b border-gray-200 px-4 py-3 dark:border-gray-700"
        >
          <.live_component
            module={ComposerComponent}
            id={edit_id(@id)}
            placeholder={label(@record_type, :placeholder)}
            notify={{__MODULE__, @id}}
            mode={:edit}
            layout={:post}
            note={@edit_note}
            fixed_subject={host_subject(item.note, @record_type, @record_id)}
            full
            cancellable
            submit_label={gettext("Save")}
            current_company={@current_company}
            current_user={@current_user}
          >
            <:header :let={roles_editable}>
              <.post_header
                note={item.note}
                progress={item.note.subject_type == "Task" and @record_type != "Task"}
                reply_to={item.d[:reply_to]}
                relation={item.relation}
                show_visibility={!roles_editable}
                current_company={@current_company}
              />
            </:header>
            <:files>
              <.file_grid
                id={"#{@id}-files"}
                attachments={item.note.attachments}
                removable
                target={@myself}
              />
            </:files>
            <:footer>
              <span title={gettext("Replies")}>💬 {item.d.replies}</span>
              <span title={gettext("Links")}>🔗 {length(item.d.links)}</span>
              <span title={gettext("Files")}>📎 {length(item.note.attachments)}</span>
            </:footer>
          </.live_component>
        </div>
        <.note_post
          :if={!editing?(item, @edit_note)}
          id={"#{@id}-note-#{item.id}"}
          item={item}
          current_company={@current_company}
          host={{@record_type, @record_id}}
          relation={item.relation}
          new_tab
        >
          <:actions :if={item.can_attach}>
            <button
              type="button"
              id={"#{@id}-edit-#{item.id}"}
              phx-click="edit_note"
              phx-value-id={item.id}
              phx-target={@myself}
              class="whitespace-nowrap rounded-full border border-gray-300 px-3 py-0.5 text-sm hover:bg-gray-100 dark:border-gray-600 dark:hover:bg-gray-800"
            >
              ✎ {gettext("Edit")}
            </button>
            <.attach_button
              id={"attach-#{item.id}"}
              url={~p"/companies/#{@current_company.id}/notes/#{item.id}/attachments"}
              company={@current_company}
            />
            <.record_buttons
              id={"record-#{item.id}"}
              url={~p"/companies/#{@current_company.id}/notes/#{item.id}/attachments"}
            />
            <.live_component
              module={PhoneQrComponent}
              id={"#{@id}-phone-#{item.id}"}
              target={{:note, item.id}}
              label={FullCircleWeb.PhoneUpload.note_label(item.note)}
              current_company={@current_company}
              current_user={@current_user}
            />
          </:actions>
        </.note_post>
      <% end %>
      <button
        :if={@total > length(@items)}
        id={"#{@id}-older"}
        type="button"
        phx-click="older"
        phx-target={@myself}
        class="block w-full px-4 py-2 text-center text-sm text-sky-600 hover:bg-gray-50 dark:text-sky-400 dark:hover:bg-gray-800"
      >
        {gettext("Show older (%{n})", n: @total - length(@items))}
      </button>
      <p :if={@items == []} class="px-4 py-3 text-sm text-gray-500">
        {label(@record_type, :empty)}
      </p>
    </section>
    """
  end
end
