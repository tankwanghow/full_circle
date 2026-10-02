defmodule FullCircleWeb.TaskLive.TasksPanelComponent do
  @moduledoc """
  Tasks that link to one record, shown beside the notes panel. A one-line
  title creates a task already linked here; the full form (new tab) is for
  due date, repeat and assignee. Contract: `.claude/skills/tasks.md`.
  """
  use FullCircleWeb, :live_component

  import FullCircleWeb.TaskComponents, only: [due_cell: 1]

  alias FullCircle.Tasks

  @impl true
  # From RecordAside's :refresh_tasks_panel hook: a task changed somewhere.
  def update(%{refresh: true}, socket),
    do: {:ok, if(socket.assigns[:loaded_for], do: load(socket), else: socket)}

  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:adding, fn -> false end)
      |> assign_new(:draft, fn -> "" end)
      |> assign_new(:error, fn -> nil end)

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

    rows =
      for task <- Tasks.for_record(t, id, com, user) do
        %{task: task, group: Tasks.group_of(task, today)}
      end

    assign(socket,
      rows: rows,
      today: today,
      can_create: Tasks.rights(com, user).create
    )
  end

  @impl true
  def handle_event("new", _, socket), do: {:noreply, assign(socket, adding: true, error: nil)}

  def handle_event("cancel", _, socket),
    do: {:noreply, assign(socket, adding: false, draft: "", error: nil)}

  def handle_event("add", %{"title" => title}, socket) do
    %{record_type: t, record_id: id, current_company: com, current_user: user} = socket.assigns
    title = String.trim(title)

    case Tasks.create_task(
           %{"title" => title, "links" => [%{"type" => t, "id" => id}]},
           com,
           user
         ) do
      {:ok, _} ->
        {:noreply, socket |> assign(adding: false, draft: "", error: nil) |> load()}

      {:error, %Ecto.Changeset{errors: [{_field, err} | _]}} ->
        {:noreply,
         assign(socket, draft: title, error: FullCircleWeb.CoreComponents.translate_error(err))}

      _ ->
        {:noreply, assign(socket, draft: title, error: gettext("Could not save the task."))}
    end
  end

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
        <.link
          :if={@can_create}
          href={
            ~p"/companies/#{@current_company.id}/tasks/new?link_type=#{@record_type}&link_id=#{@record_id}"
          }
          target="_blank"
          class="ml-auto text-xs text-gray-500 hover:underline dark:text-gray-400"
        >
          {gettext("Full form")}
        </.link>
        <button
          :if={@can_create and !@adding}
          id={"#{@id}-new"}
          type="button"
          phx-click="new"
          phx-target={@myself}
          class="rounded-full bg-sky-500 px-3 py-0.5 text-sm font-bold text-white hover:bg-sky-600"
        >
          ＋ {gettext("Task")}
        </button>
      </div>

      <form
        :if={@adding}
        id={"#{@id}-form"}
        phx-submit="add"
        phx-target={@myself}
        class="flex items-center gap-2 border-b border-gray-200 px-4 py-3 dark:border-gray-700"
      >
        <input
          type="text"
          name="title"
          value={@draft}
          placeholder={gettext("New task…")}
          class="min-w-0 flex-1 rounded-full border-0 bg-gray-100 px-4 py-1.5 text-sm focus:ring-1 focus:ring-sky-400 dark:bg-gray-800"
          autofocus
        />
        <button type="submit" class="rounded-full bg-sky-500 px-3 py-0.5 text-sm font-bold text-white">
          {gettext("Add")}
        </button>
        <button
          type="button"
          id={"#{@id}-cancel"}
          phx-click="cancel"
          phx-target={@myself}
          class="text-sm text-gray-500"
        >
          {gettext("Cancel")}
        </button>
      </form>
      <p :if={@error} class="px-4 pt-2 text-sm text-rose-600">{@error}</p>

      <.link
        :for={row <- @rows}
        id={"#{@id}-task-#{row.task.id}"}
        href={~p"/companies/#{@current_company.id}/tasks/#{row.task.id}"}
        target="_blank"
        class="flex items-center gap-2 border-b border-gray-200 px-4 py-2 text-sm last:border-0 hover:bg-sky-50/70 dark:border-gray-700 dark:hover:bg-gray-700/60"
      >
        <span class="min-w-0 flex-1 truncate font-medium">{row.task.title}</span>
        <.due_cell :if={row.task.status == "open"} task={row.task} group={row.group} today={@today} />
        <span
          :if={row.task.status != "open"}
          class="shrink-0 text-xs text-gray-500 dark:text-gray-400"
        >
          {if row.task.status == "done", do: gettext("Done"), else: gettext("Skipped")}
        </span>
      </.link>
      <p :if={@rows == []} class="px-4 py-3 text-sm text-gray-500">
        {gettext("No tasks linked to this record.")}
      </p>
    </section>
    """
  end
end
