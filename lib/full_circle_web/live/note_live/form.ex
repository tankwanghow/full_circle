defmodule FullCircleWeb.NoteLive.Form do
  use FullCircleWeb, :live_view

  import FullCircleWeb.NoteComponents

  alias FullCircle.{Linkable, Notes}
  alias FullCircle.Notes.Note
  alias FullCircleWeb.NoteLive.RecordPickerComponent

  @impl true
  def mount(params, _session, socket) do
    com = socket.assigns.current_company
    user = socket.assigns.current_user

    case socket.assigns.live_action do
      :new ->
        if FullCircle.Authorization.can?(user, :create_note, com) do
          {:ok, mount_new(socket, params)}
        else
          {:ok, deny(socket)}
        end

      :edit ->
        case Notes.get_note(params["note_id"], com, user) do
          %Note{} = note ->
            if Notes.can_edit?(note, com, user),
              do: {:ok, mount_edit(socket, note)},
              else: {:ok, deny(socket)}

          nil ->
            {:ok, deny(socket)}
        end
    end
  end

  defp deny(socket) do
    socket
    |> put_flash(:warn, gettext("You cannot edit that note."))
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
    |> assign(page_title: gettext("New Note"), note: %Note{}, subject: subject, links: [])
    |> assign(form: to_form(Notes.change_note(%Note{}, subject_attrs(subject))))
  end

  defp mount_edit(socket, note) do
    subject =
      if note.subject_type do
        case Linkable.resolve(
               note.subject_type,
               note.subject_id,
               socket.assigns.current_company,
               socket.assigns.current_user
             ) do
          {:ok, t} -> %{type: note.subject_type, id: note.subject_id, title: t.title}
          _ -> %{type: note.subject_type, id: note.subject_id, title: gettext("(unavailable)")}
        end
      end

    socket
    |> assign(page_title: gettext("Edit Note"), note: note, subject: subject, links: [])
    |> assign(form: to_form(Notes.change_note(note)))
  end

  defp subject_attrs(nil), do: %{"subject_type" => nil, "subject_id" => nil}
  defp subject_attrs(s), do: %{"subject_type" => s.type, "subject_id" => s.id}

  @impl true
  def handle_event("validate", %{"note" => params}, socket) do
    cs =
      socket.assigns.note
      |> Notes.change_note(Map.merge(params, subject_attrs(socket.assigns.subject)))
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(cs))}
  end

  def handle_event("clear_subject", _, socket) do
    {:noreply, assign(socket, subject: nil)}
  end

  def handle_event("remove_new_link", %{"id" => id}, socket) do
    {:noreply, assign(socket, links: Enum.reject(socket.assigns.links, &(&1.id == id)))}
  end

  def handle_event("save", %{"note" => params}, socket) do
    params = Map.merge(params, subject_attrs(socket.assigns.subject))
    com = socket.assigns.current_company
    user = socket.assigns.current_user

    result =
      case socket.assigns.live_action do
        :new ->
          Notes.create_note(
            Map.put(
              params,
              "links",
              Enum.map(socket.assigns.links, &%{"type" => &1.type, "id" => &1.id})
            ),
            com,
            user
          )

        :edit ->
          with {:ok, note} <- Notes.update_note(socket.assigns.note, params, com, user) do
            {:ok, note, add_links(note, socket.assigns.links, com, user)}
          end
      end

    case result do
      {:ok, note} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Note saved."))
         |> push_navigate(to: ~p"/companies/#{com.id}/notes/#{note.id}")}

      {:ok, note, []} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Note saved."))
         |> push_navigate(to: ~p"/companies/#{com.id}/notes/#{note.id}")}

      {:ok, note, _failed} ->
        {:noreply,
         socket
         |> put_flash(:warn, gettext("Note saved, but some links could not be added."))
         |> push_navigate(to: ~p"/companies/#{com.id}/notes/#{note.id}")}

      {:error, :stale} ->
        {:noreply,
         socket
         |> assign(form: to_form(Notes.change_note(socket.assigns.note, params)))
         |> put_flash(
           :warn,
           gettext("someone else changed this note — reload to see their version")
         )}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, assign(socket, form: to_form(cs))}

      {:error, {:link, :not_found}} ->
        {:noreply, put_flash(socket, :warn, gettext("A linked record no longer exists."))}

      _ ->
        {:noreply, put_flash(socket, :warn, gettext("Not Authorise."))}
    end
  end

  # One picker. With no subject yet, a pick sets the subject; once there is
  # one, picks become links (the label says which). The subject itself is
  # never also queued as a link.
  @impl true
  def handle_info({:record_picked, "record-picker", picked}, socket) do
    %{subject: subject, links: links} = socket.assigns

    cond do
      is_nil(subject) ->
        {:noreply, assign(socket, subject: picked)}

      same?(picked, subject) ->
        {:noreply, socket}

      true ->
        {:noreply, assign(socket, links: Enum.uniq_by(links ++ [picked], &{&1.type, &1.id}))}
    end
  end

  defp same?(a, b), do: a.type == b.type and a.id == b.id

  # Edit saves the note first, then adds the queued links. An existing link is
  # not a failure; anything else is reported once the note is saved.
  defp add_links(note, links, com, user) do
    for l <- links,
        not (l.type == "Note" and l.id == note.id),
        result = Notes.add_link(note, l.type, l.id, com, user),
        not match?({:ok, _}, result),
        not already_linked?(result),
        do: l
  end

  defp already_linked?({:error, %Ecto.Changeset{errors: errors}}),
    do: Enum.any?(errors, fn {_f, {msg, _}} -> msg == "already linked" end)

  defp already_linked?(_), do: false

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto w-6/12 max-md:w-11/12 rounded-lg border border-yellow-500 bg-yellow-100 p-4 dark:bg-yellow-950">
      <p class="w-full text-center text-3xl font-medium">{@page_title}</p>
      <.form for={@form} id="note-form" phx-change="validate" phx-submit="save" autocomplete="off">
        <.input field={@form[:title]} label={gettext("Title (optional)")} />
        <.input field={@form[:body]} type="textarea" rows="8" label={gettext("Note")} />

        <div class="mt-2">
          <div class="text-sm font-semibold">{gettext("Who can read this note")}</div>
          <p class="text-xs text-gray-600 dark:text-gray-400">
            {gettext("Tick none for everyone. Admin and you can always read it.")}
          </p>
          <input type="hidden" name="note[visibility][]" value="" />
          <label
            :for={role <- Note.visibility_roles()}
            class="mr-3 inline-flex items-center gap-1 text-sm"
          >
            <input
              type="checkbox"
              name="note[visibility][]"
              value={role}
              checked={role in (Ecto.Changeset.get_field(@form.source, :visibility) || [])}
            />
            {role}
          </label>
          <.error :for={msg <- Enum.map(@form[:visibility].errors, &translate_error/1)}>{msg}</.error>
        </div>

        <div class="mt-2 text-sm">
          <span class="font-semibold">{gettext("About")}:</span>
          <span
            :if={@subject}
            class="rounded border border-amber-400 bg-white px-1 dark:border-amber-600 dark:bg-gray-800"
          >
            {type_label(@subject.type)} — {@subject.title}
            <button
              type="button"
              id="clear-subject"
              phx-click="clear_subject"
              class="text-rose-600 dark:text-rose-400"
              title={gettext("Clear")}
            >
              ✕
            </button>
          </span>
          <span :if={!@subject} class="text-gray-500">{gettext("nothing in particular")}</span>
          <.error :for={
            msg <-
              Enum.map(@form[:subject_id].errors ++ @form[:subject_type].errors, &translate_error/1)
          }>
            {msg}
          </.error>
        </div>

        <div :if={@links != []} class="mt-1 text-sm">
          <span class="font-semibold">{gettext("Links")}:</span>
          <span :for={l <- @links} class="mr-2">
            {type_label(l.type)} — {l.title}
            <button
              type="button"
              phx-click="remove_new_link"
              phx-value-id={l.id}
              class="text-rose-600"
            >✕</button>
          </span>
        </div>

        <div class="mt-3 flex justify-center gap-2">
          <.button>{gettext("Save")}</.button>
          <.link navigate={~p"/companies/#{@current_company.id}/notes"} class="orange button">
            {gettext("Back")}
          </.link>
        </div>
      </.form>

      <div class="mt-3 grid gap-2">
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
    """
  end
end
