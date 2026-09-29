defmodule FullCircleWeb.NoteLive.NotesIndex do
  @moduledoc """
  Notes counts and the notes modal for a record index page. Counts are
  visibility-aware and fetched once per page load (see `Notes.count_by_records/4`).
  """
  use Phoenix.Component
  use Gettext, backend: FullCircleWeb.Gettext

  alias FullCircle.Notes

  def init(socket, record_type) do
    assign(socket, notes_type: record_type, note_counts: %{}, notes_for: nil)
  end

  def count(socket, objects, reset?) do
    counts =
      Notes.count_by_records(
        socket.assigns.current_company,
        socket.assigns.current_user,
        socket.assigns.notes_type,
        Enum.map(objects, & &1.id)
      )

    base = if reset?, do: %{}, else: socket.assigns.note_counts
    assign(socket, note_counts: Map.merge(base, counts))
  end

  def open(socket, id), do: assign(socket, notes_for: id)
  def close(socket), do: assign(socket, notes_for: nil)

  # Updates only the row. Assigning @note_counts here would re-render the
  # stream comprehension (rows read it), which empties the list's `:if`s and
  # drops the row update; the parent map is only read when rows are inserted.
  def changed(socket, id, row_module, stream_name \\ :objects) do
    n =
      Notes.count_by_records(
        socket.assigns.current_company,
        socket.assigns.current_user,
        socket.assigns.notes_type,
        [id]
      )
      |> Map.get(id, 0)

    Phoenix.LiveView.send_update(row_module, id: "#{stream_name}-#{id}", note_count: n)
    socket
  end

  attr :notes_for, :any, required: true
  attr :notes_type, :string, required: true
  attr :current_company, :map, required: true
  attr :current_user, :map, required: true

  def modal(assigns) do
    ~H"""
    <FullCircleWeb.CoreComponents.modal
      :if={@notes_for}
      id="notes-modal"
      show
      on_cancel={Phoenix.LiveView.JS.push("close_notes")}
    >
      <.live_component
        module={FullCircleWeb.NoteLive.NotesPanelComponent}
        id="notes-modal-panel"
        record_type={@notes_type}
        record_id={@notes_for}
        current_company={@current_company}
        current_user={@current_user}
        notify_parent={true}
      />
    </FullCircleWeb.CoreComponents.modal>
    """
  end
end
