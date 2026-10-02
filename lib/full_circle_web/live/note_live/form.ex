defmodule FullCircleWeb.NoteLive.Form do
  @moduledoc """
  The note's page, shaped like the feed (an x.com single-post page): the note
  as a large post, ✎ Edit turning it into the shared write box in place, files
  and history inside the post, and the replies thread below. /notes/new is the
  write box full size. /notes/:id opens the post; /notes/:id/edit opens it in
  edit mode when the user may edit. Contract: `.claude/skills/notes.md`.
  """
  use FullCircleWeb, :live_view

  import FullCircleWeb.NoteComponents

  alias FullCircle.{Linkable, Notes}
  alias FullCircle.Notes.{Attachments, Note}
  alias FullCircleWeb.NoteLive.{ComposerComponent, NotesPanelComponent}

  @impl true
  def mount(params, _session, socket) do
    %{current_company: com, current_user: user} = socket.assigns
    socket = assign(socket, show_history: false, history: [], editing: false, edit_note: nil)

    case socket.assigns.live_action do
      :new ->
        if FullCircle.Authorization.can?(user, :create_note, com),
          do: {:ok, mount_new(socket, params)},
          else: {:ok, deny(socket, gettext("You cannot create notes."))}

      action ->
        case Notes.get_note(params["note_id"], com, user) do
          %Note{} = note ->
            socket = assign_note(socket, note)

            {:ok,
             if(action == :edit and socket.assigns.can_edit,
               do: start_edit(socket),
               else: socket
             )}

          nil ->
            {:ok, deny(socket, gettext("Note not found."))}
        end
    end
  end

  defp deny(socket, msg) do
    socket
    |> put_flash(:warn, msg)
    |> push_navigate(to: ~p"/companies/#{socket.assigns.current_company.id}/notes")
  end

  defp mount_new(socket, params) do
    %{current_company: com, current_user: user} = socket.assigns

    subject =
      with t when is_binary(t) <- params["subject_type"],
           {:ok, target} <- Linkable.resolve(t, params["subject_id"], com, user) do
        %{type: t, id: target.id, title: target.title}
      else
        _ -> nil
      end

    assign(socket,
      page_title: gettext("New Note"),
      note: nil,
      item: nil,
      subject: subject,
      can_edit: false,
      can_delete: false
    )
  end

  # Everything shown for a saved note: rights, the post item, files, history.
  defp assign_note(socket, note) do
    %{current_company: com, current_user: user} = socket.assigns

    socket
    |> assign(
      page_title: gettext("Note"),
      note: note,
      can_edit: Notes.can_edit?(note, com, user),
      can_delete: Notes.can_delete?(note, com, user),
      item: %{
        id: note.id,
        note: note,
        d: Map.fetch!(Notes.feed_details([note], com, user), note.id)
      }
    )
    |> assign_history()
  end

  # The write box edits the note as it was when Edit was pressed: refreshing
  # the files mid-edit must not hand it a newer lock_version, or a save would
  # silently overwrite someone else's edit instead of reporting it as stale.
  defp start_edit(socket),
    do: assign(socket, editing: true, edit_note: socket.assigns.note)

  defp stop_edit(socket), do: assign(socket, editing: false, edit_note: nil)

  defp reload(socket) do
    %{note: note, current_company: com, current_user: user} = socket.assigns

    case Notes.get_note(note.id, com, user) do
      nil -> deny(socket, gettext("Note not found."))
      fresh -> assign_note(socket, fresh)
    end
  end

  defp assign_history(%{assigns: %{show_history: false}} = socket),
    do: assign(socket, history: [])

  defp assign_history(socket) do
    %{note: note, current_company: com, current_user: user} = socket.assigns
    assign(socket, history: Notes.version_changes(Notes.list_versions(note, com, user), note))
  end

  @impl true
  def handle_event("edit", _, socket) do
    if socket.assigns.can_edit and not socket.assigns.editing,
      do: {:noreply, start_edit(socket)},
      else: {:noreply, socket}
  end

  def handle_event("toggle_history", _, socket),
    do:
      {:noreply, socket |> assign(show_history: !socket.assigns.show_history) |> assign_history()}

  def handle_event("attachment_uploaded", _, socket), do: {:noreply, reload(socket)}

  def handle_event("remove_attachment", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.note.attachments, &(&1.id == id)) do
      nil ->
        {:noreply, socket}

      att ->
        Attachments.remove(att, socket.assigns.current_company, socket.assigns.current_user)
        {:noreply, reload(socket)}
    end
  end

  def handle_event("delete", _, socket) do
    %{note: note, current_company: com, current_user: user} = socket.assigns

    case Notes.delete_note(note, com, user) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Note deleted."))
         |> push_navigate(to: ~p"/companies/#{com.id}/notes")}

      _ ->
        {:noreply, put_flash(socket, :warn, gettext("Not Authorise."))}
    end
  end

  @impl true
  def handle_info({:composer, "note", {:saved, :new, note}}, socket) do
    {:noreply,
     socket
     |> put_flash(:info, gettext("Note saved."))
     |> push_navigate(to: ~p"/companies/#{socket.assigns.current_company.id}/notes/#{note.id}")}
  end

  def handle_info({:composer, "note", {:saved, :edit, _note}}, socket) do
    {:noreply, socket |> stop_edit() |> reload() |> put_flash(:info, gettext("Note saved."))}
  end

  # Links on a saved note apply immediately, so a cancelled edit still reloads.
  def handle_info({:composer, "note", :cancelled}, socket),
    do: {:noreply, socket |> stop_edit() |> reload()}

  # A reply was posted in the thread: refresh the post's 💬 count.
  def handle_info({:notes_changed, "Note", _id}, socket), do: {:noreply, reload(socket)}

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp edited?(%Note{} = note), do: note.updated_at != note.inserted_at

  defp show_value(nil), do: "—"
  defp show_value(list) when is_list(list), do: Enum.join(list, ", ")
  defp show_value(v), do: to_string(v)

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-xl border-x border-gray-200 bg-white dark:border-gray-700 dark:bg-gray-900">
      <div class="flex items-center gap-4 border-b border-gray-200 px-4 py-2 dark:border-gray-700">
        <.link
          id="back-to-notes"
          navigate={~p"/companies/#{@current_company.id}/notes"}
          class="rounded-full px-2 text-xl hover:bg-gray-100 dark:hover:bg-gray-800"
          title={gettext("Back")}
        >
          ←
        </.link>
        <span class="text-lg font-bold">{@page_title}</span>
        <details :if={@can_delete} class="relative ml-auto">
          <summary class="cursor-pointer list-none rounded-full px-2 text-xl hover:bg-gray-100 dark:hover:bg-gray-800">
            ⋯
          </summary>
          <div class="absolute right-0 z-10 mt-1 w-40 rounded-lg border border-gray-200 bg-white py-1 shadow-lg dark:border-gray-700 dark:bg-gray-800">
            <button
              type="button"
              id="delete-note"
              phx-click="delete"
              data-confirm={gettext("Delete this note? Its history is kept.")}
              class="block w-full px-3 py-1.5 text-left text-sm text-rose-700 hover:bg-rose-50 dark:text-rose-300 dark:hover:bg-rose-950"
            >
              {gettext("Delete")}
            </button>
          </div>
        </details>
      </div>

      <div :if={is_nil(@note)} class="px-4 py-3">
        <.live_component
          module={ComposerComponent}
          id="note"
          full
          avatar
          initial_subject={@subject}
          current_company={@current_company}
          current_user={@current_user}
        />
        <p class="mt-2 text-xs text-gray-500 dark:text-gray-400">
          {gettext("Save the note first, then attach files.")}
        </p>
      </div>

      <%= if @note do %>
        <.note_post
          :if={!@editing}
          id="note-post"
          item={@item}
          current_company={@current_company}
          detail
        >
          <:actions>
            <button
              :if={@can_edit}
              type="button"
              id="edit-note"
              phx-click="edit"
              class="rounded-full border border-gray-300 px-3 py-0.5 text-sm hover:bg-gray-100 dark:border-gray-600 dark:hover:bg-gray-800"
            >
              ✎ {gettext("Edit")}
            </button>
            <.attach_button :if={@can_edit} note_id={@note.id} current_company={@current_company} />
            <button
              type="button"
              id="toggle-history"
              phx-click="toggle_history"
              class="text-xs text-gray-500 hover:underline dark:text-gray-400"
            >
              {gettext("History")} {if @show_history, do: "▾", else: "▸"}
            </button>
          </:actions>
        </.note_post>

        <div :if={@editing} class="border-b border-gray-200 px-4 py-3 dark:border-gray-700">
          <.live_component
            module={ComposerComponent}
            id="note"
            mode={:edit}
            note={@edit_note}
            full
            avatar
            cancellable
            submit_label={gettext("Save")}
            current_company={@current_company}
            current_user={@current_user}
          />
          <div id="note-files" class="mt-3">
            <div class="mb-2 flex items-center">
              <span class="text-sm font-semibold">📎 {gettext("Files")}</span>
              <span class="ml-auto">
                <.attach_button note_id={@note.id} current_company={@current_company} />
              </span>
            </div>
            <.attachment_tiles
              attachments={@note.attachments}
              current_company={@current_company}
              can_edit
            />
          </div>
          <button
            type="button"
            id="toggle-history"
            phx-click="toggle_history"
            class="mt-2 text-xs text-gray-500 hover:underline dark:text-gray-400"
          >
            {gettext("History")} {if @show_history, do: "▾", else: "▸"}
          </button>
        </div>

        <div
          :if={@show_history}
          id="note-history"
          class="border-b border-gray-200 px-4 py-2 text-sm dark:border-gray-700"
        >
          <p :if={edited?(@note)} class="text-xs text-gray-500 dark:text-gray-400">
            {gettext("edited by")} {@note.updated_by && @note.updated_by.email} · {FullCircleWeb.Helpers.format_datetime(
              @note.updated_at,
              @current_company
            )}
          </p>
          <div
            :for={h <- @history}
            class="my-1 rounded border border-gray-200 p-2 dark:border-gray-700"
          >
            <div class="text-xs text-gray-500 dark:text-gray-400">
              {gettext("Version")} {h.version.version} · {gettext("replaced by")} {h.version.edited_by.email}
              {FullCircleWeb.Helpers.format_datetime(h.version.inserted_at, @current_company)}
            </div>
            <div :for={{field, old, new} <- h.changes}>
              <span class="font-semibold">{field}</span>: <span
                phx-no-format
                class="whitespace-pre-wrap bg-rose-100 line-through dark:bg-rose-900"
              >{show_value(old)}</span> →
              <span class="whitespace-pre-wrap bg-green-100 dark:bg-green-900">{show_value(new)}</span>
            </div>
          </div>
          <p :if={@history == []} class="text-gray-500 dark:text-gray-400">
            {gettext("Never edited.")}
          </p>
        </div>

        <.live_component
          module={NotesPanelComponent}
          id="notes-panel"
          layout={:thread}
          record_type="Note"
          record_id={@note.id}
          notify_parent
          current_company={@current_company}
          current_user={@current_user}
        />
      <% end %>
    </div>
    """
  end
end
