defmodule FullCircleWeb.NoteLive.NotesPanelComponent do
  @moduledoc """
  Notes about, or linking to, one record. Rendered under a record's edit form
  and inside the index-page notes modal. Self-contained: all events target it.
  """
  use FullCircleWeb, :live_component

  import FullCircleWeb.NoteComponents

  alias FullCircle.Notes
  alias FullCircle.Notes.{Attachments, Note}

  # The host form re-renders on every keystroke (phx-change="validate"), which
  # calls update/2 each time. Only (re)load when the record changes, or the
  # panel would query per keystroke and wipe a half-typed quick-add.
  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:notify_parent, fn -> false end)
      |> assign_new(:adding, fn -> false end)

    key = {socket.assigns.record_type, socket.assigns.record_id}

    if socket.assigns[:loaded_for] == key do
      {:ok, socket}
    else
      {:ok,
       socket
       |> assign(loaded_for: key, adding: false, form: to_form(Notes.change_note(%Note{})))
       |> load()}
    end
  end

  defp load(socket) do
    %{record_type: t, record_id: id, current_company: com, current_user: user} = socket.assigns
    rows = Notes.notes_for_record(t, id, com, user)
    # Every row is already visible, so edit rights need no per-note query.
    rights = Notes.rights(com, user)

    assign(socket,
      rows: rows,
      editable: MapSet.new(for r <- rows, Notes.may_edit?(r.note, user, rights), do: r.note.id),
      can_create: rights.create
    )
  end

  @impl true
  def handle_event("new", _, socket), do: {:noreply, assign(socket, adding: true)}
  def handle_event("cancel", _, socket), do: {:noreply, assign(socket, adding: false)}

  def handle_event("validate", %{"note" => params}, socket) do
    cs = %Note{} |> Notes.change_note(params) |> Map.put(:action, :validate)
    {:noreply, assign(socket, form: to_form(cs))}
  end

  def handle_event("save", %{"note" => params}, socket) do
    %{record_type: t, record_id: id, current_company: com, current_user: user} = socket.assigns
    attrs = Map.merge(params, %{"subject_type" => t, "subject_id" => id})

    case Notes.create_note(attrs, com, user) do
      {:ok, _note} ->
        if socket.assigns.notify_parent, do: send(self(), {:notes_changed, t, id})

        {:noreply,
         socket |> assign(adding: false, form: to_form(Notes.change_note(%Note{}))) |> load()}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, assign(socket, form: to_form(cs))}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("attachment_uploaded", _, socket), do: {:noreply, load(socket)}

  def handle_event("remove_attachment", %{"id" => att_id}, socket) do
    att =
      socket.assigns.rows
      |> Enum.flat_map(& &1.note.attachments)
      |> Enum.find(&(&1.id == att_id))

    if att,
      do: Attachments.remove(att, socket.assigns.current_company, socket.assigns.current_user)

    {:noreply, load(socket)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id={@id}
      class="mx-auto mt-3 rounded-lg border border-blue-300 bg-blue-50 p-3 dark:border-blue-700 dark:bg-blue-950"
    >
      <div class="flex items-center">
        <span class="font-semibold">📝 {gettext("Notes")} ({length(@rows)})</span>
        <span class="ml-auto flex gap-2">
          <button
            :if={@can_create and !@adding}
            id={"#{@id}-new"}
            type="button"
            phx-click="new"
            phx-target={@myself}
            class="blue button"
          >
            + {gettext("Note")}
          </button>
          <.link
            :if={@can_create}
            navigate={"/companies/#{@current_company.id}/notes/new?subject_type=#{@record_type}&subject_id=#{@record_id}"}
            class="text-sm text-blue-600 hover:font-bold dark:text-blue-400"
          >
            {gettext("Full form")}
          </.link>
        </span>
      </div>

      <.form
        :if={@adding}
        for={@form}
        id={"#{@id}-form"}
        phx-change="validate"
        phx-submit="save"
        phx-target={@myself}
        class="mt-2"
      >
        <.input
          field={@form[:body]}
          type="textarea"
          rows="3"
          placeholder={gettext("Write a note...")}
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
        <div class="text-xs">
          {gettext("Readable by")} ({gettext("tick none for everyone")}):
          <input type="hidden" name="note[visibility][]" value="" />
          <label :for={role <- Note.visibility_roles()} class="mr-2 inline-flex items-center gap-1">
            <input type="checkbox" name="note[visibility][]" value={role} />{role}
          </label>
        </div>
        <div class="mt-1 flex gap-2">
          <.button>{gettext("Save")}</.button>
          <button type="button" phx-click="cancel" phx-target={@myself} class="orange button">
            {gettext("Cancel")}
          </button>
        </div>
        <p class="text-xs text-gray-500">{gettext("Attach files after saving.")}</p>
      </.form>

      <.note_card
        :for={r <- @rows}
        note={r.note}
        relation={r.relation}
        current_company={@current_company}
        can_edit={MapSet.member?(@editable, r.note.id)}
        target={@myself}
      />
      <p :if={@rows == []} class="text-sm text-gray-500">{gettext("No notes yet.")}</p>
    </div>
    """
  end
end
