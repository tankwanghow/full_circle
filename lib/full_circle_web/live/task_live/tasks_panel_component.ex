defmodule FullCircleWeb.TaskLive.TasksPanelComponent do
  @moduledoc """
  Tasks that link to one record, shown beside the notes panel, drawn as the
  Tasks list draws them. ＋ Task and ✎ Edit open the task write box
  (`TaskFormComponent`) in place, always linked to this record. A task's
  progress notes stay on the task page. Contract: `.claude/skills/tasks.md`.
  """
  use FullCircleWeb, :live_component

  import FullCircleWeb.TaskComponents, only: [close_buttons: 1, close_dialog: 1, task_row: 1]

  alias FullCircle.Tasks
  alias FullCircleWeb.TaskLive.TaskFormComponent

  @impl true
  # From RecordAside's :refresh_tasks_panel hook: a task changed somewhere.
  def update(%{refresh: true}, socket),
    do: {:ok, if(socket.assigns[:loaded_for], do: load(socket), else: socket)}

  # The write box (＋ Task: `id-new`, ✎ Edit: `id-edit`) finished. Links on a
  # saved task apply at once, so any finish reloads.
  def update(%{task_form: {_cid, event}}, socket) do
    case event do
      :links_changed -> {:ok, socket}
      _ -> {:ok, socket |> assign(adding: false, edit_task: nil) |> load()}
    end
  end

  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:adding, fn -> false end)
      |> assign_new(:edit_task, fn -> nil end)
      |> assign_new(:closing, fn -> nil end)

    key = {socket.assigns.record_type, socket.assigns.record_id}

    if socket.assigns[:loaded_for] == key do
      {:ok, socket}
    else
      {:ok, socket |> assign(loaded_for: key, adding: false) |> load()}
    end
  end

  defp load(socket) do
    %{record_type: t, record_id: id, current_company: com, current_user: user} = socket.assigns
    today = Tasks.today(com)

    # The Tasks list's rows, so a task looks the same here as there.
    rows = Tasks.rows(Tasks.for_record(t, id, com, user), com, user, today)

    rights = Tasks.rights(com, user)

    rows =
      for row <- rows do
        open? = row.task.status == "open"

        Map.merge(row, %{
          can_edit: open? and Tasks.may_edit?(row.task, user, rights),
          can_close: open? and Tasks.may_close?(row.task, user, rights)
        })
      end

    assign(socket, rows: rows, today: today, can_create: rights.create)
  end

  @impl true
  def handle_event("new", _, socket), do: {:noreply, assign(socket, adding: true)}

  # The box edits the task as it was when Edit was pressed (lock_version).
  def handle_event("edit_task", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.rows, &(&1.id == id and &1.can_edit)) do
      nil -> {:noreply, socket}
      row -> {:noreply, assign(socket, edit_task: row.task)}
    end
  end

  # Done / Skip, as on the Tasks list: the dialog asks for an optional
  # progress line, then closes the task (a repeating one opens its next cycle).
  def handle_event("open_close", %{"id" => id, "kind" => kind}, socket) do
    %{current_company: com, current_user: user} = socket.assigns

    case Tasks.get_task(id, com, user) do
      nil ->
        {:noreply, socket |> put_flash(:warn, gettext("Task not found.")) |> load()}

      task ->
        kind = if kind == "skip", do: :skipped, else: :done

        next_due =
          task.recur_unit && Tasks.next_due_date(task.due_date, task.recur_unit, task.recur_every)

        {:noreply, assign(socket, closing: %{task: task, kind: kind, next_due: next_due})}
    end
  end

  def handle_event("cancel_close", _, socket), do: {:noreply, assign(socket, closing: nil)}

  def handle_event("confirm_close", _, %{assigns: %{closing: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("confirm_close", %{"close" => %{"note" => note}}, socket) do
    %{closing: %{task: task, kind: kind}, current_company: com, current_user: user} =
      socket.assigns

    socket = assign(socket, closing: nil)

    case Tasks.close_task(task, kind, note, com, user) do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, gettext("Task closed.")) |> load()}

      {:error, :already_closed} ->
        {:noreply,
         socket |> put_flash(:warn, gettext("Someone already closed this task.")) |> load()}

      _ ->
        {:noreply, put_flash(socket, :warn, gettext("Not Authorise."))}
    end
  end

  defp editing?(%{id: id}, %{id: id}), do: true
  defp editing?(_row, _edit_task), do: false

  @impl true
  def render(assigns) do
    ~H"""
    <section
      id={@id}
      class={[
        "overflow-hidden rounded-xl border border-gray-200 bg-white dark:border-gray-700 dark:bg-gray-900",
        @class
      ]}
    >
      <div class="flex items-center gap-2 border-b border-gray-200 px-4 py-2 dark:border-gray-700">
        <span class="font-semibold">✅ {gettext("Tasks")}</span>
        <span class="text-sm text-gray-500">{length(@rows)}</span>
        <button
          :if={@can_create and !@adding}
          id={"#{@id}-new"}
          type="button"
          phx-click="new"
          phx-target={@myself}
          class="ml-auto rounded-full bg-sky-500 px-3 py-0.5 text-sm font-bold text-white hover:bg-sky-600"
        >
          ＋ {gettext("Task")}
        </button>
      </div>

      <%!-- ＋ Task opens the full task form here, linked to this record, so the
           panel needs no "Full form" link to /tasks/new. --%>
      <div :if={@adding} class="border-b border-gray-200 px-4 py-3 dark:border-gray-700">
        <.live_component
          module={TaskFormComponent}
          id={"#{@id}-new-task"}
          task={%FullCircle.Tasks.CompanyTask{}}
          host={{@record_type, @record_id}}
          notify={{__MODULE__, @id}}
          cancellable
          current_company={@current_company}
          current_user={@current_user}
        />
      </div>

      <%= for row <- @rows do %>
        <div
          :if={editing?(row, @edit_task)}
          id={"#{@id}-editing"}
          class="border-b border-gray-200 px-4 py-3 dark:border-gray-700"
        >
          <.live_component
            module={TaskFormComponent}
            id={"#{@id}-edit"}
            mode={:edit}
            task={@edit_task}
            host={{@record_type, @record_id}}
            notify={{__MODULE__, @id}}
            cancellable
            current_company={@current_company}
            current_user={@current_user}
          >
            <:footer>
              <span title={gettext("Progress")}>📝 {row.note_count}</span>
              <span>🔗 {row.link_count}</span>
            </:footer>
          </.live_component>
        </div>
        <.task_row
          :if={!editing?(row, @edit_task)}
          id={"#{@id}-task-#{row.task.id}"}
          item={row}
          today={@today}
          company={@current_company}
          new_tab
        >
          <:actions :if={row.can_edit or row.can_close}>
          <button
            :if={row.can_edit}
            type="button"
            id={"#{@id}-edit-#{row.task.id}"}
            phx-click="edit_task"
            phx-value-id={row.task.id}
            phx-target={@myself}
            class="mr-10 rounded-full border border-gray-300 px-2.5 py-0.5 text-xs hover:bg-gray-100 dark:border-gray-600 dark:hover:bg-gray-800"
          >
            ✎ {gettext("Edit")}
          </button>
            <.close_buttons :if={row.can_close} task_id={row.task.id} target={@myself} />
          </:actions>
        </.task_row>
      <% end %>
      <p :if={@rows == []} class="px-4 py-3 text-sm text-gray-500">
        {gettext("No tasks linked to this record.")}
      </p>
      <.close_dialog :if={@closing} closing={@closing} target={@myself} />
    </section>
    """
  end
end
