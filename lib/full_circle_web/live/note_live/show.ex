defmodule FullCircleWeb.NoteLive.Show do
  use FullCircleWeb, :live_view

  import FullCircleWeb.NoteComponents

  alias FullCircle.{Linkable, Notes}
  alias FullCircle.Notes.{Attachments, Note}
  alias FullCircleWeb.NoteLive.RecordPickerComponent

  @impl true
  def mount(%{"note_id" => id}, _session, socket) do
    case Notes.get_note(id, socket.assigns.current_company, socket.assigns.current_user) do
      %Note{} = note ->
        {:ok, socket |> assign(show_history: false) |> load(note)}

      nil ->
        {:ok,
         socket
         |> put_flash(:warn, gettext("Note not found."))
         |> push_navigate(to: ~p"/companies/#{socket.assigns.current_company.id}/notes")}
    end
  end

  defp load(socket, note) do
    com = socket.assigns.current_company
    user = socket.assigns.current_user

    subject =
      note.subject_type && Linkable.resolve(note.subject_type, note.subject_id, com, user)

    socket
    |> assign(
      page_title: Note.display_title(note),
      note: note,
      subject: subject,
      can_edit: Notes.can_edit?(note, com, user),
      can_delete: Notes.can_delete?(note, com, user),
      links: Notes.list_links(note, com, user),
      backlinks: Notes.list_backlinks(note, com, user)
    )
    |> assign_history()
  end

  defp assign_history(%{assigns: %{show_history: false}} = socket),
    do: assign(socket, history: [])

  defp assign_history(socket) do
    %{note: note, current_company: com, current_user: user} = socket.assigns
    assign(socket, history: Notes.version_changes(Notes.list_versions(note, com, user), note))
  end

  defp reload(socket) do
    case Notes.get_note(
           socket.assigns.note.id,
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      nil -> push_navigate(socket, to: ~p"/companies/#{socket.assigns.current_company.id}/notes")
      note -> load(socket, note)
    end
  end

  @impl true
  def handle_event("toggle_history", _, socket) do
    {:noreply, socket |> assign(show_history: !socket.assigns.show_history) |> assign_history()}
  end

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

  def handle_event("remove_link", %{"id" => link_id}, socket) do
    Notes.remove_link(
      socket.assigns.note,
      link_id,
      socket.assigns.current_company,
      socket.assigns.current_user
    )

    {:noreply, reload(socket)}
  end

  def handle_event("delete", _, socket) do
    case Notes.delete_note(
           socket.assigns.note,
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Note deleted."))
         |> push_navigate(to: ~p"/companies/#{socket.assigns.current_company.id}/notes")}

      _ ->
        {:noreply, put_flash(socket, :warn, gettext("Not Authorise."))}
    end
  end

  @impl true
  def handle_info({:record_picked, "link-picker", %{type: t, id: id}}, socket) do
    case Notes.add_link(
           socket.assigns.note,
           t,
           id,
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, _} ->
        {:noreply, reload(socket)}

      {:error, %Ecto.Changeset{}} ->
        {:noreply, put_flash(socket, :warn, gettext("Already linked."))}

      _ ->
        {:noreply, put_flash(socket, :warn, gettext("Could not link that record."))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto w-7/12 max-md:w-11/12">
      <div class="flex flex-wrap items-center gap-2 text-sm text-gray-600 dark:text-gray-400">
        <.visibility_badge visibility={@note.visibility} />
        <span>{@note.author.email}</span>
        <span>· {FullCircleWeb.Helpers.format_datetime(@note.inserted_at, @current_company)}</span>
        <span :if={@note.updated_at != @note.inserted_at}>
          · {gettext("edited by")} {@note.updated_by.email}
          {FullCircleWeb.Helpers.format_datetime(@note.updated_at, @current_company)}
        </span>
      </div>
      <h1 :if={@note.title} class="mt-1 text-2xl font-semibold">{@note.title}</h1>
      <div :if={@subject} class="mt-1 text-sm">
        {gettext("About")}: <.record_link target={@subject} type={@note.subject_type} />
      </div>
      <%!-- pre-wrap renders any whitespace around the body, so keep it inline --%>
      <div
        phx-no-format
        class="mt-2 whitespace-pre-wrap rounded border border-gray-300 bg-white p-3 dark:border-gray-600 dark:bg-gray-800"
      >{@note.body}</div>

      <div class="mt-2">
        <.attachment_list
          attachments={@note.attachments}
          current_company={@current_company}
          can_edit={@can_edit}
        />
        <.attach_button :if={@can_edit} note_id={@note.id} current_company={@current_company} />
      </div>

      <div class="mt-3 flex gap-2">
        <.link
          :if={@can_edit}
          navigate={~p"/companies/#{@current_company.id}/notes/#{@note.id}/edit"}
          class="blue button"
        >
          {gettext("Edit")}
        </.link>
        <button
          :if={@can_delete}
          id="delete-note"
          phx-click="delete"
          data-confirm={gettext("Delete this note? Its history is kept.")}
          class="red button"
        >
          {gettext("Delete")}
        </button>
        <.link navigate={~p"/companies/#{@current_company.id}/notes"} class="orange button">{gettext(
          "Back"
        )}</.link>
      </div>

      <h2 class="mt-4 font-semibold">{gettext("Links")}</h2>
      <div :for={l <- @links} class="flex items-center gap-2 text-sm">
        <.record_link target={l.target} type={l.type} />
        <button
          :if={@can_edit}
          id={"remove-link-#{l.link_id}"}
          phx-click="remove_link"
          phx-value-id={l.link_id}
          class="text-rose-600 dark:text-rose-400"
        >
          ✕
        </button>
      </div>
      <p :if={@links == []} class="text-sm text-gray-500">{gettext("No links.")}</p>
      <div :if={@can_edit} class="mt-1">
        <.live_component
          module={RecordPickerComponent}
          id="link-picker"
          label={gettext("Link a record")}
          current_company={@current_company}
          current_user={@current_user}
        />
      </div>

      <h2 class="mt-4 font-semibold">{gettext("Notes linking here")}</h2>
      <div :for={b <- @backlinks} class="text-sm">
        <.link
          navigate={~p"/companies/#{@current_company.id}/notes/#{b.id}"}
          class="text-blue-600 hover:font-bold dark:text-blue-400"
        >
          {Note.display_title(b)}
        </.link>
      </div>
      <p :if={@backlinks == []} class="text-sm text-gray-500">{gettext("None.")}</p>

      <button
        id="toggle-history"
        phx-click="toggle_history"
        class="mt-4 font-semibold text-blue-600 dark:text-blue-400"
      >
        {if @show_history, do: "▾", else: "▸"} {gettext("History")}
      </button>
      <div :if={@show_history}>
        <div
          :for={h <- @history}
          class="my-1 rounded border border-gray-300 p-2 text-sm dark:border-gray-600"
        >
          <div class="text-xs text-gray-500">
            {gettext("Version")} {h.version.version} · {gettext("replaced by")} {h.version.edited_by.email}
            {FullCircleWeb.Helpers.format_datetime(h.version.inserted_at, @current_company)}
          </div>
          <div :for={{field, old, new} <- h.changes}>
            <span class="font-semibold">{field}</span>: <span
              phx-no-format
              class="whitespace-pre-wrap bg-rose-100 line-through dark:bg-rose-900"
            >{inspect_value(old)}</span> →
            <span class="whitespace-pre-wrap bg-green-100 dark:bg-green-900">{inspect_value(new)}</span>
          </div>
        </div>
        <p :if={@history == []} class="text-sm text-gray-500">{gettext("Never edited.")}</p>
      </div>
    </div>
    """
  end

  defp inspect_value(nil), do: "—"
  defp inspect_value(list) when is_list(list), do: Enum.join(list, ", ")
  defp inspect_value(v), do: to_string(v)
end
