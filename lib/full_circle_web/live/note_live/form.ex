defmodule FullCircleWeb.NoteLive.Form do
  @moduledoc """
  The note's page, shaped like the feed (an x.com single-post page): the note
  as a large post, ✎ Edit turning it into the shared write box in place, files
  and history inside the post, and its replies below as compact comments.
  /notes/new is the write box full size. /notes/:id opens the post;
  /notes/:id/edit opens it in edit mode when the user may edit.

  A conversation has one page, its root's. /notes/:reply renders the root's
  page with that reply scrolled to and flashed (and /notes/:reply/edit with it
  in edit mode), so opening replies never stacks pages. Only a reply whose root
  is deleted or hidden gets a page of its own. Contract: `.claude/skills/notes.md`.
  """
  use FullCircleWeb, :live_view

  import FullCircleWeb.NoteComponents

  alias FullCircle.{Linkable, Notes, Repo}
  alias FullCircle.Notes.{Attachments, Note}
  alias FullCircleWeb.NoteLive.{ComposerComponent, PhoneQrComponent}

  @impl true
  def mount(params, _session, socket) do
    %{current_company: com, current_user: user} = socket.assigns

    socket =
      assign(socket,
        show_history: false,
        history: [],
        editing: false,
        edit_note: nil,
        focus_id: nil,
        reply_edit: nil,
        reply_history_id: nil,
        reply_history: []
      )

    case socket.assigns.live_action do
      :new ->
        if FullCircle.Authorization.can?(user, :create_note, com),
          do: {:ok, mount_new(socket, params)},
          else: {:ok, deny(socket, gettext("You cannot create notes."))}

      action ->
        case Notes.get_note(params["note_id"], com, user) do
          %Note{} = note ->
            {page_note, focus_id} = thread_page(note, com, user)
            socket = socket |> assign(focus_id: focus_id) |> assign_note(page_note)

            {:ok,
             cond do
               action != :edit -> socket
               focus_id -> start_reply_edit(socket, focus_id)
               socket.assigns.can_edit -> start_edit(socket)
               true -> socket
             end}

          nil ->
            {:ok, deny(socket, gettext("Note not found."))}
        end
    end
  end

  # A reply opens on its root's page, focused on the reply. A root, or a reply
  # whose root is deleted or hidden, is its own page.
  defp thread_page(note, com, user) do
    case Notes.root_of(note, com, user) do
      {:root, root} -> {Repo.preload(root, [:author, :updated_by, :attachments]), note.id}
      _ -> {note, nil}
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
      can_delete: false,
      root_state: :self,
      replies: [],
      backlinks: [],
      can_reply: false
    )
  end

  # Everything shown for a saved note: rights, the post item, files, history.
  defp assign_note(socket, note) do
    %{current_company: com, current_user: user} = socket.assigns
    FullCircleWeb.NoteFiles.listen_self({:note, note.id})

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
    |> assign_thread()
    |> assign_history()
    |> assign_reply_history()
  end

  # The conversation under the page's note: its replies (each with its own
  # rights), and notes that only link here. The page's note is a root, unless
  # it is a reply whose root is deleted or hidden (`root_state`), which has no
  # thread and takes no replies.
  defp assign_thread(socket) do
    %{note: note, current_company: com, current_user: user} = socket.assigns
    rights = Notes.rights(com, user)

    root_state =
      case Notes.root_of(note, com, user) do
        :self -> :self
        {:root, _} -> :ok
        {state, nil} -> state
      end

    replies =
      if root_state == :self do
        for r <- Notes.thread(note, com, user) do
          FullCircleWeb.NoteFiles.listen_self({:note, r.id})

          Map.merge(r, %{
            can_edit: Notes.may_edit?(r.note, user, rights),
            can_delete: Notes.may_delete?(r.note, user, rights)
          })
        end
      else
        []
      end

    # A reply that also links here is already shown in the thread.
    in_thread = MapSet.new([note | Enum.map(replies, & &1.note)], & &1.id)

    backlinks =
      note
      |> Notes.list_backlinks(com, user)
      |> Enum.reject(&MapSet.member?(in_thread, &1.id))
      |> Repo.preload([:author, :attachments])
      |> then(fn notes ->
        d = Notes.feed_details(notes, com, user)
        Enum.map(notes, &%{id: &1.id, note: &1, d: Map.fetch!(d, &1.id)})
      end)

    assign(socket,
      root_state: root_state,
      replies: replies,
      backlinks: backlinks,
      can_reply: rights.create and root_state == :self
    )
  end

  defp find_reply(socket, id), do: Enum.find(socket.assigns.replies, &(&1.id == id))

  # Like start_edit/1: the box edits the reply as it was when Edit was pressed.
  defp start_reply_edit(socket, id) do
    case find_reply(socket, id) do
      %{can_edit: true, note: note} -> assign(socket, reply_edit: note, editing: false)
      _ -> socket
    end
  end

  defp assign_reply_history(%{assigns: %{reply_history_id: nil}} = socket),
    do: assign(socket, reply_history: [])

  defp assign_reply_history(socket) do
    %{reply_history_id: id, current_company: com, current_user: user} = socket.assigns

    case find_reply(socket, id) do
      nil ->
        assign(socket, reply_history_id: nil, reply_history: [])

      %{note: note} ->
        history = Notes.version_changes(Notes.list_versions(note, com, user), note)
        assign(socket, reply_history: history)
    end
  end

  # The write box edits the note as it was when Edit was pressed: refreshing
  # the files mid-edit must not hand it a newer lock_version, or a save would
  # silently overwrite someone else's edit instead of reporting it as stale.
  defp start_edit(socket),
    do: assign(socket, editing: true, edit_note: socket.assigns.note, reply_edit: nil)

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

  # /notes/new has no saved note yet; these events only exist on a note's page.
  def handle_event(event, _, %{assigns: %{note: nil}} = socket)
      when event in ~w(delete toggle_history attachment_uploaded remove_attachment
                       edit_reply toggle_reply_history delete_reply),
      do: {:noreply, socket}

  def handle_event("toggle_history", _, socket),
    do:
      {:noreply, socket |> assign(show_history: !socket.assigns.show_history) |> assign_history()}

  def handle_event("edit_reply", %{"id" => id}, socket),
    do: {:noreply, start_reply_edit(socket, id)}

  def handle_event("toggle_reply_history", %{"id" => id}, socket) do
    open = if socket.assigns.reply_history_id == id, do: nil, else: id
    {:noreply, socket |> assign(reply_history_id: open) |> assign_reply_history()}
  end

  def handle_event("delete_reply", %{"id" => id}, socket) do
    %{current_company: com, current_user: user} = socket.assigns

    with %{can_delete: true, note: note} <- find_reply(socket, id),
         {:ok, _} <- Notes.delete_note(note, com, user) do
      {:noreply, socket |> reload() |> put_flash(:info, gettext("Reply deleted."))}
    else
      _ -> {:noreply, put_flash(socket, :warn, gettext("Not Authorise."))}
    end
  end

  def handle_event("attachment_uploaded", _, socket), do: {:noreply, reload(socket)}

  # A file on the page's note, or on a reply this user may edit.
  def handle_event("remove_attachment", %{"id" => id}, socket) do
    %{note: note, replies: replies} = socket.assigns

    removable =
      note.attachments ++ for(r <- replies, r.can_edit, a <- r.note.attachments, do: a)

    case Enum.find(removable, &(&1.id == id)) do
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

  def handle_info({:composer, "reply-edit", {:saved, :edit, _note}}, socket),
    do:
      {:noreply,
       socket |> assign(reply_edit: nil) |> reload() |> put_flash(:info, gettext("Reply saved."))}

  def handle_info({:composer, "reply-edit", :cancelled}, socket),
    do: {:noreply, socket |> assign(reply_edit: nil) |> reload()}

  # A reply was posted in the thread: refresh the thread and the 💬 count.
  def handle_info({:composer, "reply", {:saved, :new, _}}, socket), do: {:noreply, reload(socket)}

  # A file landed on this note (phone, another tab): show it.
  def handle_info({:note_files, {:note, _}}, socket), do: {:noreply, reload(socket)}

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp edited?(%Note{} = note), do: note.updated_at != note.inserted_at

  attr :id, :string, required: true
  attr :note, Note, required: true
  attr :history, :list, required: true
  attr :current_company, :map, required: true

  # A note's edit history (per-version filtered by Notes.list_versions/3); used
  # for the page's note and for each reply.
  defp history_list(assigns) do
    ~H"""
    <div id={@id} class="border-b border-gray-200 px-4 py-2 text-sm dark:border-gray-700">
      <p :if={edited?(@note)} class="text-xs text-gray-500 dark:text-gray-400">
        {gettext("edited by")} {@note.updated_by && @note.updated_by.email} · {FullCircleWeb.Helpers.format_datetime(
          @note.updated_at,
          @current_company
        )}
      </p>
      <div :for={h <- @history} class="my-1 rounded border border-gray-200 p-2 dark:border-gray-700">
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
    """
  end

  attr :r, :map, required: true, doc: "a thread item with can_edit / can_delete"
  attr :root, Note, required: true
  attr :focus, :boolean, default: false, doc: "the reply the page was opened on"
  attr :edit_note, :any, default: false, doc: "the reply as it was when ✎ Edit was pressed"
  attr :history, :any, default: false, doc: "its version list while History is open"
  attr :current_company, :map, required: true
  attr :current_user, :map, required: true

  # One reply as a compact comment under the root. It repeats nothing the root
  # already says (subject chip, visibility, "↩ reply to"): replies always share
  # the root's subject and visibility. Links of its own still show.
  defp reply_item(assigns) do
    assigns =
      assign(assigns,
        note: assigns.r.note,
        links: Enum.reject(assigns.r.d.links, &(&1.type == "Note" and &1.id == assigns.root.id))
      )

    ~H"""
    <article
      id={"reply-#{@r.id}"}
      data-reply
      phx-hook={@focus && "ScrollToNote"}
      class="flex gap-2 px-4 py-2"
    >
      <.avatar email={@note.author.email} small />
      <div class="min-w-0 flex-1">
        <%= if @edit_note do %>
          <.live_component
            module={ComposerComponent}
            id="reply-edit"
            mode={:edit}
            layout={:post}
            note={@edit_note}
            full
            cancellable
            submit_label={gettext("Save")}
            current_company={@current_company}
            current_user={@current_user}
          >
            <:header :let={roles_editable}>
              <.post_header
                note={@note}
                show_visibility={!roles_editable}
                current_company={@current_company}
              />
            </:header>
            <:files>
              <.file_grid
                id={"reply-edit-files-#{@r.id}"}
                attachments={@note.attachments}
                removable
              />
            </:files>
            <:footer>
              <span title={gettext("Files")}>📎 {length(@note.attachments)}</span>
            </:footer>
          </.live_component>
        <% else %>
          <div class="flex flex-wrap items-baseline gap-x-1 text-sm">
            <span class="font-bold">{@note.author.email |> String.split("@") |> hd()}</span>
            <span class="text-xs text-gray-500 dark:text-gray-400">
              {FullCircleWeb.Helpers.format_datetime(@note.inserted_at, @current_company)}
            </span>
            <span :if={edited?(@note)} class="text-xs text-gray-500 dark:text-gray-400">
              · {gettext("edited")}
            </span>
          </div>
          <div :if={@note.title} class="font-bold">{@note.title}</div>
          <div phx-no-format class="whitespace-pre-wrap break-words">{@note.body}</div>
          <div :if={@links != []} class="mt-1 flex flex-wrap gap-1">
            <.record_chip :for={l <- @links} target={l.target} type={l.type} />
          </div>
          <.file_grid id={"reply-files-#{@r.id}"} attachments={@note.attachments} />
          <div class="@container mt-1 flex flex-wrap items-center gap-1.5 text-xs text-gray-500 dark:text-gray-400">
            <button
              :if={@r.can_edit}
              type="button"
              id={"edit-reply-#{@r.id}"}
              phx-click="edit_reply"
              phx-value-id={@r.id}
              class="hover:underline"
            >
              ✎ {gettext("Edit")}
            </button>
            <.attach_button
              :if={@r.can_edit}
              id={"attach-#{@r.id}"}
              url={~p"/companies/#{@current_company.id}/notes/#{@r.id}/attachments"}
              company={@current_company}
            />
            <.live_component
              :if={@r.can_edit}
              module={PhoneQrComponent}
              id={"reply-phone-#{@r.id}"}
              target={{:note, @r.id}}
              label={FullCircleWeb.PhoneUpload.note_label(@note)}
              current_company={@current_company}
              current_user={@current_user}
            />
            <button
              type="button"
              id={"toggle-reply-history-#{@r.id}"}
              phx-click="toggle_reply_history"
              phx-value-id={@r.id}
              class="hover:underline"
            >
              {gettext("History")} {if @history, do: "▾", else: "▸"}
            </button>
            <button
              :if={@r.can_delete}
              type="button"
              id={"delete-reply-#{@r.id}"}
              phx-click="delete_reply"
              phx-value-id={@r.id}
              data-confirm={gettext("Delete this reply? Its history is kept.")}
              class="text-rose-600 hover:underline dark:text-rose-400"
            >
              {gettext("Delete")}
            </button>
          </div>
          <.history_list
            :if={@history}
            id={"reply-history-#{@r.id}"}
            note={@note}
            history={@history}
            current_company={@current_company}
          />
        <% end %>
      </div>
    </article>
    """
  end

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
        <%!-- Only a reply whose root is gone (deleted, hidden) is its own page. --%>
        <p
          :if={@root_state in [:deleted, :hidden]}
          id="replying-to-gone"
          class="border-b border-gray-200 bg-slate-50/70 px-4 py-2 text-sm text-slate-500 dark:border-gray-700 dark:bg-gray-800/40 dark:text-slate-400"
        >
          {if @root_state == :deleted,
            do: gettext("Replying to a deleted note"),
            else: gettext("Replying to a note you can't see")}
        </p>

        <div id="focus-note">
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
                class="whitespace-nowrap rounded-full border border-gray-300 px-3 py-0.5 text-sm hover:bg-gray-100 dark:border-gray-600 dark:hover:bg-gray-800"
              >
                ✎ {gettext("Edit")}
              </button>
              <.attach_button
                :if={@can_edit}
                id={"attach-#{@note.id}"}
                url={~p"/companies/#{@current_company.id}/notes/#{@note.id}/attachments"}
                company={@current_company}
              />
              <.live_component
                :if={@can_edit}
                module={PhoneQrComponent}
                id="note-phone"
                target={{:note, @note.id}}
                label={FullCircleWeb.PhoneUpload.note_label(@note)}
                current_company={@current_company}
                current_user={@current_user}
              />
              <button
                type="button"
                id="toggle-history"
                phx-click="toggle_history"
                class="whitespace-nowrap text-xs text-gray-500 hover:underline dark:text-gray-400"
              >
                {gettext("History")} {if @show_history, do: "▾", else: "▸"}
              </button>
            </:actions>
          </.note_post>

          <%!-- Edit keeps the post's layout: the same header, chips, text, file
               grid and counts row, each turned into its field. --%>
          <div :if={@editing} class="border-b border-gray-200 px-4 py-3 dark:border-gray-700">
            <.live_component
              module={ComposerComponent}
              id="note"
              mode={:edit}
              layout={:post}
              note={@edit_note}
              full
              cancellable
              submit_label={gettext("Save")}
              current_company={@current_company}
              current_user={@current_user}
            >
              <:header :let={roles_editable}>
                <.post_header
                  note={@note}
                  progress={@note.subject_type == "Task"}
                  reply_to={@item.d[:reply_to]}
                  detail
                  show_visibility={!roles_editable}
                  current_company={@current_company}
                />
              </:header>
              <:files>
                <.file_grid id="note-files" attachments={@note.attachments} removable />
              </:files>
              <:footer>
                <span title={gettext("Replies")}>💬 {@item.d.replies}</span>
                <span title={gettext("Links")}>🔗 {length(@item.d.links)}</span>
                <span title={gettext("Files")}>📎 {length(@note.attachments)}</span>
              </:footer>
              <:actions>
                <button
                  type="button"
                  id="toggle-history"
                  phx-click="toggle_history"
                  class="text-xs text-gray-500 hover:underline dark:text-gray-400"
                >
                  {gettext("History")} {if @show_history, do: "▾", else: "▸"}
                </button>
              </:actions>
            </.live_component>
          </div>
        </div>

        <.history_list
          :if={@show_history}
          id="note-history"
          note={@note}
          history={@history}
          current_company={@current_company}
        />

        <section
          :if={@replies != []}
          id="replies"
          class="border-b border-gray-200 dark:border-gray-700"
        >
          <p class="px-4 pt-2 text-xs font-semibold uppercase tracking-wide text-slate-500 dark:text-slate-400">
            {ngettext("1 reply", "%{count} replies", length(@replies))}
          </p>
          <.reply_item
            :for={r <- @replies}
            r={r}
            root={@note}
            focus={r.id == @focus_id}
            edit_note={@reply_edit && @reply_edit.id == r.id && @reply_edit}
            history={@reply_history_id == r.id && @reply_history}
            current_company={@current_company}
            current_user={@current_user}
          />
        </section>

        <div
          :if={@can_reply}
          class="border-b border-gray-200 px-4 py-3 dark:border-gray-700"
        >
          <.live_component
            module={ComposerComponent}
            id="reply"
            reply_to={@note}
            avatar
            placeholder={gettext("Reply to %{title}…", title: Note.display_title(@note))}
            submit_label={gettext("Reply")}
            current_company={@current_company}
            current_user={@current_user}
          />
        </div>

        <section
          :if={@backlinks != []}
          id="linked-from"
          class="border-t border-gray-200 dark:border-gray-700"
        >
          <p class="px-4 pt-2 text-xs font-semibold uppercase tracking-wide text-slate-500 dark:text-slate-400">
            {gettext("Linked from")}
          </p>
          <.note_post
            :for={i <- @backlinks}
            id={"linked-#{i.id}"}
            item={i}
            current_company={@current_company}
            host={{"Note", @note.id}}
            relation={:linked}
          />
        </section>
      <% end %>
    </div>
    """
  end
end
