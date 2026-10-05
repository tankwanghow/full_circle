defmodule FullCircleWeb.NoteLive.NotesIndex do
  @moduledoc """
  Notes counts, open-task counts and the notes modal for a record index page.
  Counts are visibility-aware and fetched once per page load (see
  `Notes.count_by_records/4`, `Tasks.open_count_by_records/4`). The modal shows
  the record's notes panel with its tasks panel below, as the record page does.
  """
  use Phoenix.Component
  use Gettext, backend: FullCircleWeb.Gettext

  alias FullCircle.{Notes, Tasks}
  alias FullCircleWeb.TaskLive.TasksPanelComponent

  @doc """
  Sets up notes counts and the notes modal on an index LiveView. Call from
  `mount/3`. It attaches its own `handle_event` ("open_notes", "open_tasks",
  "close_notes") and `handle_info` (`{:notes_changed, _, _}`, and
  `{:tasks_changed, _}` from `Tasks.topic/1`, which it subscribes to) hooks, so
  the index only calls `count/3` where it streams rows and renders `modal/1`.

  `row_module` is the index's row live_component (updated in place when a
  count changes). Options:
    * `:key` — the row field holding the record's id (default `:id`; deposit
      and return-cheque rows are transactions carrying it elsewhere)
    * `:stream` — the stream name (default `:objects`)
  """
  def init(socket, record_type, row_module, opts \\ []) do
    key = Keyword.get(opts, :key, :id)
    stream = Keyword.get(opts, :stream, :objects)

    if Phoenix.LiveView.connected?(socket),
      do:
        Phoenix.PubSub.subscribe(
          FullCircle.PubSub,
          Tasks.topic(socket.assigns.current_company.id)
        )

    socket
    |> assign(
      notes_type: record_type,
      notes_key: key,
      note_counts: %{},
      task_counts: %{},
      notes_rows: %{},
      notes_for: nil
    )
    |> Phoenix.LiveView.attach_hook(:notes_events, :handle_event, fn
      "open_notes", %{"id" => id}, s -> {:halt, open(s, id)}
      "open_tasks", %{"id" => id}, s -> {:halt, open(s, id)}
      "close_notes", _params, s -> {:halt, close(s)}
      _event, _params, s -> {:cont, s}
    end)
    |> Phoenix.LiveView.attach_hook(:notes_info, :handle_info, fn
      {:notes_changed, _type, id}, s -> {:halt, changed(s, id, row_module, stream)}
      {:tasks_changed, _company_id}, s -> {:halt, tasks_changed(s, row_module, stream)}
      _msg, s -> {:cont, s}
    end)
  end

  def count(socket, objects, reset?) do
    key = socket.assigns.notes_key

    rows =
      for o <- objects, rid = Map.get(o, key), reduce: %{} do
        acc -> Map.update(acc, rid, [o.id], &[o.id | &1])
      end

    %{current_company: com, current_user: user, notes_type: type} = socket.assigns
    counts = Notes.count_by_records(com, user, type, Map.keys(rows))
    tasks = Tasks.open_count_by_records(com, user, type, Map.keys(rows))

    {base_counts, base_tasks, base_rows} =
      if reset?,
        do: {%{}, %{}, %{}},
        else: {socket.assigns.note_counts, socket.assigns.task_counts, socket.assigns.notes_rows}

    assign(socket,
      note_counts: Map.merge(base_counts, counts),
      task_counts: Map.merge(base_tasks, tasks),
      notes_rows: Map.merge(base_rows, rows, fn _, a, b -> Enum.uniq(a ++ b) end)
    )
  end

  def open(socket, id), do: assign(socket, notes_for: id)
  def close(socket), do: assign(socket, notes_for: nil)

  # Updates only the rows. Assigning @note_counts here would re-render the
  # stream comprehension (rows read it), which drops the row update; the
  # parent map is only read when rows are inserted.
  def changed(socket, id, row_module, stream_name \\ :objects) do
    n =
      Notes.count_by_records(
        socket.assigns.current_company,
        socket.assigns.current_user,
        socket.assigns.notes_type,
        [id]
      )
      |> Map.get(id, 0)

    for row_id <- Map.get(socket.assigns.notes_rows, id, [id]) do
      Phoenix.LiveView.send_update(row_module, id: "#{stream_name}-#{row_id}", note_count: n)
    end

    socket
  end

  # A task changed somewhere in the company (this modal, another tab, another
  # user): recount the page's records in one query and push the new count to
  # every row. Like changed/4 it leaves @task_counts alone, so the stream rows
  # take the update. The modal's tasks panel reloads too.
  def tasks_changed(socket, row_module, stream_name \\ :objects) do
    %{current_company: com, current_user: user, notes_type: type, notes_rows: rows} =
      socket.assigns

    counts = Tasks.open_count_by_records(com, user, type, Map.keys(rows))

    for {record_id, row_ids} <- rows, row_id <- row_ids do
      Phoenix.LiveView.send_update(row_module,
        id: "#{stream_name}-#{row_id}",
        task_count: Map.get(counts, record_id, 0)
      )
    end

    if socket.assigns.notes_for,
      do:
        Phoenix.LiveView.send_update(TasksPanelComponent, id: "notes-modal-tasks", refresh: true)

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
      <.live_component
        module={TasksPanelComponent}
        id="notes-modal-tasks"
        record_type={@notes_type}
        record_id={@notes_for}
        current_company={@current_company}
        current_user={@current_user}
        class="mt-2"
      />
    </FullCircleWeb.CoreComponents.modal>
    """
  end
end
