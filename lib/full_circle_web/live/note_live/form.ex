defmodule FullCircleWeb.NoteLive.Form do
  @moduledoc """
  The note's one page: create, read and edit (there is no separate show page,
  like every other FullCircle record). Users who can read a note but not edit
  it get the same page with the inputs locked.

  Title, body, visibility and the subject are form fields saved with Save.
  Files and links on a saved note take effect immediately, like elsewhere in
  FullCircle; on a new note, picked links are queued and saved with the note.
  """
  use FullCircleWeb, :live_view

  import FullCircleWeb.NoteComponents

  alias FullCircle.{Linkable, Notes}
  alias FullCircle.Notes.{Attachments, Note}
  alias FullCircleWeb.NoteLive.RecordPickerComponent

  @impl true
  def mount(params, _session, socket) do
    com = socket.assigns.current_company
    user = socket.assigns.current_user

    socket = assign(socket, show_picker: false, show_history: false, history: [], params: %{})

    case socket.assigns.live_action do
      :new ->
        if FullCircle.Authorization.can?(user, :create_note, com),
          do: {:ok, mount_new(socket, params)},
          else: {:ok, deny(socket, gettext("You cannot create notes."))}

      :edit ->
        case Notes.get_note(params["note_id"], com, user) do
          %Note{} = note -> {:ok, mount_edit(socket, note)}
          nil -> {:ok, deny(socket, gettext("Note not found."))}
        end
    end
  end

  defp deny(socket, msg) do
    socket
    |> put_flash(:warn, msg)
    |> push_navigate(to: ~p"/companies/#{socket.assigns.current_company.id}/notes")
  end

  defp mount_new(socket, params) do
    subject =
      with t when is_binary(t) <- params["subject_type"],
           {:ok, target} <-
             Linkable.resolve(
               t,
               params["subject_id"],
               socket.assigns.current_company,
               socket.assigns.current_user
             ) do
        %{type: t, id: target.id, title: target.title}
      else
        _ -> nil
      end

    socket
    |> assign(
      page_title: gettext("New Note"),
      note: %Note{},
      subject: subject,
      links: [],
      can_edit: true,
      can_delete: false
    )
    |> assign(form: to_form(Notes.change_note(%Note{}, subject_attrs(subject))))
  end

  defp mount_edit(socket, note) do
    %{current_company: com, current_user: user} = socket.assigns
    can_edit = Notes.can_edit?(note, com, user)

    socket
    |> assign(
      page_title: if(can_edit, do: gettext("Edit Note"), else: gettext("Note")),
      can_edit: can_edit,
      can_delete: Notes.can_delete?(note, com, user)
    )
    |> assign_note(note)
  end

  # Everything that follows the saved note: the form, subject, links and
  # backlinks. Called on mount and after a successful save.
  defp assign_note(socket, note) do
    %{current_company: com, current_user: user} = socket.assigns

    socket
    |> assign(
      note: note,
      subject: subject_of(note, com, user),
      form: to_form(Notes.change_note(note)),
      params: %{},
      links: Notes.list_links(note, com, user)
    )
    |> assign_history()
  end

  defp subject_of(%Note{subject_type: nil}, _com, _user), do: nil

  defp subject_of(%Note{subject_type: t, subject_id: id}, com, user) do
    case Linkable.resolve(t, id, com, user) do
      {:ok, target} -> %{type: t, id: id, title: target.title}
      _ -> %{type: t, id: id, title: gettext("(unavailable)")}
    end
  end

  # Files and links change without a Save. Refresh them without touching the
  # form (half-typed text) or the note's lock_version (a concurrent-edit guard).
  defp refresh_related(socket) do
    %{note: note, current_company: com, current_user: user} = socket.assigns

    case Notes.get_note(note.id, com, user) do
      nil ->
        deny(socket, gettext("Note not found."))

      fresh ->
        assign(socket,
          note: %{note | attachments: fresh.attachments},
          links: Notes.list_links(note, com, user)
        )
    end
  end

  defp assign_history(%{assigns: %{show_history: false}} = socket),
    do: assign(socket, history: [])

  defp assign_history(socket) do
    %{note: note, current_company: com, current_user: user} = socket.assigns
    assign(socket, history: Notes.version_changes(Notes.list_versions(note, com, user), note))
  end

  defp subject_attrs(nil), do: %{"subject_type" => nil, "subject_id" => nil}
  defp subject_attrs(s), do: %{"subject_type" => s.type, "subject_id" => s.id}

  defp change(socket, params) do
    cs =
      socket.assigns.note
      |> Notes.change_note(Map.merge(params, subject_attrs(socket.assigns.subject)))
      |> Map.put(:action, :validate)

    assign(socket, form: to_form(cs), params: params)
  end

  @impl true
  def handle_event("validate", %{"note" => params}, socket),
    do: {:noreply, change(socket, params)}

  def handle_event("visibility_everyone", _, socket),
    do: {:noreply, change(socket, Map.put(socket.assigns.params, "visibility", [""]))}

  def handle_event("clear_subject", _, socket), do: {:noreply, assign(socket, subject: nil)}

  def handle_event("toggle_picker", _, socket),
    do: {:noreply, assign(socket, show_picker: !socket.assigns.show_picker)}

  def handle_event("toggle_history", _, socket) do
    {:noreply, socket |> assign(show_history: !socket.assigns.show_history) |> assign_history()}
  end

  def handle_event("remove_new_link", %{"id" => id}, socket) do
    {:noreply, assign(socket, links: Enum.reject(socket.assigns.links, &(&1.id == id)))}
  end

  def handle_event("remove_link", %{"id" => link_id}, socket) do
    Notes.remove_link(
      socket.assigns.note,
      link_id,
      socket.assigns.current_company,
      socket.assigns.current_user
    )

    {:noreply, refresh_related(socket)}
  end

  def handle_event("attachment_uploaded", _, socket), do: {:noreply, refresh_related(socket)}

  def handle_event("remove_attachment", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.note.attachments, &(&1.id == id)) do
      nil ->
        {:noreply, socket}

      att ->
        Attachments.remove(att, socket.assigns.current_company, socket.assigns.current_user)
        {:noreply, refresh_related(socket)}
    end
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

  def handle_event("save", %{"note" => params}, socket) do
    params = Map.merge(params, subject_attrs(socket.assigns.subject))
    com = socket.assigns.current_company
    user = socket.assigns.current_user

    case socket.assigns.live_action do
      :new ->
        links = Enum.map(socket.assigns.links, &%{"type" => &1.type, "id" => &1.id})

        case Notes.create_note(Map.put(params, "links", links), com, user) do
          {:ok, note} ->
            {:noreply,
             socket
             |> put_flash(:info, gettext("Note saved."))
             |> push_navigate(to: ~p"/companies/#{com.id}/notes/#{note.id}/edit")}

          error ->
            {:noreply, save_error(socket, error, params)}
        end

      :edit ->
        case Notes.update_note(socket.assigns.note, params, com, user) do
          {:ok, note} ->
            {:noreply, socket |> assign_note(note) |> put_flash(:info, gettext("Note saved."))}

          error ->
            {:noreply, save_error(socket, error, params)}
        end
    end
  end

  defp save_error(socket, {:error, :stale}, params) do
    socket
    |> assign(form: to_form(Notes.change_note(socket.assigns.note, params)))
    |> put_flash(:warn, gettext("someone else changed this note — reload to see their version"))
  end

  defp save_error(socket, {:error, %Ecto.Changeset{} = cs}, _params),
    do: assign(socket, form: to_form(cs))

  defp save_error(socket, {:error, {:link, :not_found}}, _params),
    do: put_flash(socket, :warn, gettext("A linked record no longer exists."))

  defp save_error(socket, _, _params), do: put_flash(socket, :warn, gettext("Not Authorise."))

  # One picker. With no subject yet, a pick sets the subject; once there is
  # one, picks become links (the label says which). On a saved note a link is
  # added straight away; on a new note it is queued until Save.
  @impl true
  def handle_info({:record_picked, "record-picker", picked}, socket) do
    %{subject: subject, note: note} = socket.assigns
    socket = assign(socket, show_picker: false)

    cond do
      picked.type == "Note" and picked.id == note.id and is_nil(subject) ->
        {:noreply, put_flash(socket, :warn, gettext("A note cannot be about itself."))}

      is_nil(subject) ->
        {:noreply, assign(socket, subject: picked)}

      picked.type == subject.type and picked.id == subject.id ->
        {:noreply, socket}

      socket.assigns.live_action == :new ->
        links = Enum.uniq_by(socket.assigns.links ++ [picked], &{&1.type, &1.id})
        {:noreply, assign(socket, links: links)}

      true ->
        {:noreply, add_link(socket, picked)}
    end
  end

  defp add_link(socket, picked) do
    %{note: note, current_company: com, current_user: user} = socket.assigns

    case Notes.add_link(note, picked.type, picked.id, com, user) do
      {:ok, _} ->
        refresh_related(socket)

      # The changeset says which rule refused it ("already linked", "cannot
      # link to itself"); show that, not a blanket guess.
      {:error, %Ecto.Changeset{errors: [{_field, error} | _]}} ->
        put_flash(socket, :warn, FullCircleWeb.CoreComponents.translate_error(error))

      _ ->
        put_flash(socket, :warn, gettext("Could not link that record."))
    end
  end

  # Links on a saved note come from list_links (%{link_id, type, id, target});
  # queued ones on a new note are the picker's %{type, id, title}.
  defp link_title(%{title: t}), do: t
  defp link_title(%{target: {:ok, t}}), do: t.title
  defp link_title(%{target: {:error, :restricted}}), do: gettext("Restricted record")
  defp link_title(%{type: type}), do: "(#{gettext("deleted")} #{type_label(type)})"

  # Records open in a new tab (FullCircle's doc_link convention): their pages
  # have no "back to where I came from", so the note stays open behind them.
  defp link_url(%{target: {:ok, t}}, _company), do: t.url
  defp link_url(%{target: _}, _company), do: nil
  defp link_url(%{type: type, id: id}, company), do: Linkable.url(type, id, company)

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto w-6/12 max-md:w-11/12">
      <div class="rounded-lg border border-yellow-500 bg-yellow-100 p-4 dark:border-yellow-700 dark:bg-yellow-950">
        <p class="w-full text-center text-3xl font-medium">{@page_title}</p>
        <p
          :if={@live_action == :edit}
          class="mb-2 text-center text-xs text-gray-600 dark:text-gray-400"
        >
          {gettext("Written by")} {@note.author.email} · {FullCircleWeb.Helpers.format_datetime(
            @note.inserted_at,
            @current_company
          )}
          <span :if={@note.updated_at != @note.inserted_at}>
            · {gettext("edited by")} {@note.updated_by.email}
            {FullCircleWeb.Helpers.format_datetime(@note.updated_at, @current_company)}
          </span>
        </p>

        <.form for={@form} id="note-form" phx-change="validate" phx-submit="save" autocomplete="off">
          <.input field={@form[:title]} label={gettext("Title (optional)")} disabled={!@can_edit} />
          <.input
            field={@form[:body]}
            type="textarea"
            rows="6"
            label={gettext("Note")}
            disabled={!@can_edit}
          />

          <div class="mt-3">
            <div class="flex flex-wrap items-center gap-1">
              <span
                class="mr-1 text-sm font-semibold"
                title={gettext("Admin and the writer can always read it.")}
              >
                {gettext("Readable by")}
              </span>
              <button
                type="button"
                id="visibility-everyone"
                phx-click="visibility_everyone"
                disabled={!@can_edit}
                class={[
                  "rounded-full border px-2 text-xs",
                  if(selected_roles(@form) == [],
                    do:
                      "border-green-400 bg-green-100 text-green-800 dark:border-green-600 dark:bg-green-900 dark:text-green-100",
                    else:
                      "border-gray-300 bg-white text-gray-600 dark:border-gray-600 dark:bg-gray-800 dark:text-gray-300"
                  )
                ]}
              >
                {if selected_roles(@form) == [], do: "● ", else: ""}{gettext("Everyone")}
              </button>
              <input type="hidden" name="note[visibility][]" value="" />
              <.role_chip
                :for={role <- Note.visibility_roles()}
                role={role}
                selected={role in selected_roles(@form)}
                disabled={!@can_edit}
              />
            </div>
            <.error :for={msg <- Enum.map(@form[:visibility].errors, &translate_error/1)}>
              {msg}
            </.error>
          </div>

          <div class="mt-2">
            <div class="flex flex-wrap items-center gap-1">
              <span class="mr-1 text-sm font-semibold">{gettext("About & links")}</span>
              <span
                :if={@subject}
                class="rounded-full border border-amber-400 bg-amber-100 px-2 text-xs text-amber-900 dark:border-amber-600 dark:bg-amber-900 dark:text-amber-100"
              >
                <a
                  href={Linkable.url(@subject.type, @subject.id, @current_company)}
                  target="_blank"
                  class="hover:underline"
                >
                  {type_label(@subject.type)} · {@subject.title}
                </a>
                <button
                  :if={@can_edit}
                  type="button"
                  id="clear-subject"
                  phx-click="clear_subject"
                  title={gettext("Clear")}
                >
                  ✕
                </button>
              </span>
              <span
                :for={l <- @links}
                class="rounded-full border border-sky-400 bg-sky-100 px-2 text-xs text-sky-900 dark:border-sky-600 dark:bg-sky-900 dark:text-sky-100"
              >
                <a
                  :if={link_url(l, @current_company)}
                  href={link_url(l, @current_company)}
                  target="_blank"
                  class="hover:underline"
                >
                  {type_label(l.type)} · {link_title(l)}
                </a>
                <span :if={!link_url(l, @current_company)}>
                  {type_label(l.type)} · {link_title(l)}
                </span>
                <button
                  :if={@can_edit and @live_action == :edit}
                  type="button"
                  id={"remove-link-#{l.link_id}"}
                  phx-click="remove_link"
                  phx-value-id={l.link_id}
                  title={gettext("Remove")}
                >
                  ✕
                </button>
                <button
                  :if={@live_action == :new}
                  type="button"
                  phx-click="remove_new_link"
                  phx-value-id={l.id}
                  title={gettext("Remove")}
                >
                  ✕
                </button>
              </span>
              <button
                :if={@can_edit}
                type="button"
                id="open-picker"
                phx-click="toggle_picker"
                class="rounded-full border border-dashed border-gray-400 px-2 text-xs text-gray-600 hover:bg-white dark:border-gray-500 dark:text-gray-300 dark:hover:bg-gray-800"
              >
                ＋ {if @subject, do: gettext("link a record"), else: gettext("what is it about?")}
              </button>
              <span
                :if={!@subject and @links == [] and !@can_edit}
                class="text-xs text-gray-500"
              >
                {gettext("nothing in particular")}
              </span>
            </div>
            <.error :for={
              msg <-
                Enum.map(
                  @form[:subject_id].errors ++ @form[:subject_type].errors,
                  &translate_error/1
                )
            }>
              {msg}
            </.error>
          </div>

          <div class="mt-4 flex justify-center gap-2">
            <.button :if={@can_edit}>{gettext("Save")}</.button>
            <.link navigate={~p"/companies/#{@current_company.id}/notes"} class="orange button">
              {gettext("Back")}
            </.link>
            <button
              :if={@can_delete}
              type="button"
              id="delete-note"
              phx-click="delete"
              data-confirm={gettext("Delete this note? Its history is kept.")}
              class="red button"
            >
              {gettext("Delete")}
            </button>
          </div>
        </.form>

        <div :if={@show_picker} class="mt-3">
          <.live_component
            module={RecordPickerComponent}
            id="record-picker"
            label={
              if @subject,
                do: gettext("Link other records"),
                else: gettext("Set what this note is about")
            }
            current_company={@current_company}
            current_user={@current_user}
          />
        </div>
      </div>

      <%!-- Three boxes under the card: files, notes about this note, history. --%>
      <section class="mt-3 rounded-lg border border-gray-200 bg-white/70 p-3 dark:border-gray-700 dark:bg-gray-900/40">
        <div class="mb-2 flex items-center">
          <h2 class="text-sm font-semibold">
            📎 {gettext("Files")}
            <span :if={@live_action == :edit and @note.attachments != []} class="text-gray-500">
              ({length(@note.attachments)})
            </span>
          </h2>
          <span :if={@live_action == :edit and @can_edit} class="ml-auto">
            <.attach_button note_id={@note.id} current_company={@current_company} />
          </span>
        </div>
        <%= if @live_action == :edit do %>
          <.attachment_tiles
            attachments={@note.attachments}
            current_company={@current_company}
            can_edit={@can_edit}
          />
          <p :if={@note.attachments == []} class="text-sm text-gray-500">{gettext("None")}</p>
        <% else %>
          <p class="text-sm text-gray-500">{gettext("Save the note first, then attach files.")}</p>
        <% end %>
      </section>

      <%!-- Notes about this note (and notes linking to it): the same panel as
           on every record page, so follow-ups can be added right here. --%>
      <.live_component
        :if={@live_action == :edit}
        module={FullCircleWeb.NoteLive.NotesPanelComponent}
        id="notes-panel"
        record_type="Note"
        record_id={@note.id}
        current_company={@current_company}
        current_user={@current_user}
      />

      <section
        :if={@live_action == :edit}
        class="mt-3 rounded-lg border border-gray-200 bg-white/70 p-3 dark:border-gray-700 dark:bg-gray-900/40"
      >
        <button
          id="toggle-history"
          type="button"
          phx-click="toggle_history"
          class="text-sm font-semibold hover:text-blue-700 dark:hover:text-blue-300"
        >
          {if @show_history, do: "▾", else: "▸"} 🕘 {gettext("History")}
        </button>
        <div :if={@show_history} class="mt-2">
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
              >{show_value(old)}</span> →
              <span class="whitespace-pre-wrap bg-green-100 dark:bg-green-900">{show_value(new)}</span>
            </div>
          </div>
          <p :if={@history == []} class="text-sm text-gray-500">{gettext("Never edited.")}</p>
        </div>
      </section>
    </div>
    """
  end

  defp selected_roles(form), do: Ecto.Changeset.get_field(form.source, :visibility) || []

  defp show_value(nil), do: "—"
  defp show_value(list) when is_list(list), do: Enum.join(list, ", ")
  defp show_value(v), do: to_string(v)
end
