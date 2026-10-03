defmodule FullCircleWeb.TaskLive.Form do
  @moduledoc """
  The task's one page, a column 15% wider than Notes. An open task starts as a
  post; Edit, new and copy keep that post and turn the lines into fields.
  Progress (notes about the task, so labelled) copies the task's visibility. Past cycles sit under the post.
  """
  use FullCircleWeb, :live_view

  import FullCircleWeb.NoteComponents

  import FullCircleWeb.TaskComponents,
    only: [close_dialog: 1, due_tile: 1, people_line: 1, rhythm: 1]

  alias FullCircle.{Linkable, Notes, Tasks}
  alias FullCircle.Tasks.CompanyTask
  alias FullCircleWeb.NoteLive.RecordPickerComponent
  alias FullCircleWeb.TaskLive.TaskFormComponent

  @impl true
  def mount(params, _session, socket) do
    %{current_company: com, current_user: user} = socket.assigns

    socket =
      assign(socket,
        show_picker: false,
        closing: nil,
        editing: false,
        today: Tasks.today(com),
        note_count: 0,
        link_count: 0,
        users: Tasks.assignable_users(com),
        rights: Tasks.rights(com, user)
      )

    case socket.assigns.live_action do
      :new ->
        if socket.assigns.rights.create,
          do: {:ok, mount_new(socket, %CompanyTask{}, gettext("New Task"), params)},
          else: {:ok, deny(socket, gettext("You cannot create tasks."))}

      :copy ->
        with {:rights, true} <- {:rights, socket.assigns.rights.create},
             {:task, %CompanyTask{} = src} <-
               {:task, Tasks.get_task(params["task_id"], com, user)} do
          {:ok, mount_new(socket, copy_of(src, socket.assigns.users), gettext("Copy Task"), %{})}
        else
          {:rights, _} -> {:ok, deny(socket, gettext("You cannot create tasks."))}
          {:task, _} -> {:ok, deny(socket, gettext("Task not found."))}
        end

      :edit ->
        case Tasks.get_task(params["task_id"], com, user) do
          %CompanyTask{} = task -> {:ok, assign_task(socket, task)}
          nil -> {:ok, deny(socket, gettext("Task not found."))}
        end
    end
  end

  defp deny(socket, msg) do
    socket
    |> put_flash(:warn, msg)
    |> push_navigate(to: ~p"/companies/#{socket.assigns.current_company.id}/tasks")
  end

  # The item-specific parts (links, notes, cycles, series, status) are left
  # behind. An assignee who can no longer be assigned is dropped, so the copy
  # can be saved and the "keep a demoted assignee" option rule never applies.
  defp copy_of(src, users) do
    assignee_id = if Enum.any?(users, &(&1.id == src.assignee_id)), do: src.assignee_id

    %CompanyTask{
      title: src.title,
      descriptions: src.descriptions,
      due_date: src.due_date,
      recur_unit: src.recur_unit,
      recur_every: src.recur_every,
      reminder_before_days: src.reminder_before_days,
      documents_needed: src.documents_needed,
      assignee_id: assignee_id,
      visibility: src.visibility
    }
  end

  defp mount_new(socket, prefill, title, params) do
    links = link_from_params(params, socket)

    assign(socket,
      page_title: title,
      task: prefill,
      links: links,
      link_count: length(links),
      cycles: [],
      cycle_counts: %{},
      can_edit: true,
      can_close: false,
      can_reopen: false,
      editing: false
    )
  end

  # /tasks/new?link_type=&link_id= opens the full form with that record already
  # linked (the panel's "Full form"). A bad id is ignored.
  defp link_from_params(%{"link_type" => type, "link_id" => id}, socket)
       when is_binary(type) and is_binary(id) do
    %{current_company: com, current_user: user} = socket.assigns

    case Linkable.resolve(type, id, com, user) do
      {:ok, target} -> [%{type: type, id: id, title: target.title}]
      _ -> []
    end
  end

  defp link_from_params(_, _socket), do: []

  defp assign_task(socket, task) do
    %{current_company: com, current_user: user, rights: r} = socket.assigns
    open? = task.status == "open"
    cycles = Tasks.series_cycles(task, com, user)
    links = Tasks.list_links(task, com, user)
    note_counts = Notes.count_by_records(com, user, "Task", [task.id | Enum.map(cycles, & &1.id)])

    assign(socket,
      page_title: gettext("Task"),
      task: task,
      links: links,
      link_count: length(links),
      note_count: Map.get(note_counts, task.id, 0),
      cycles: cycles,
      cycle_counts: Map.delete(note_counts, task.id),
      can_edit: open? and Tasks.may_edit?(task, user, r),
      can_close: open? and Tasks.may_close?(task, user, r),
      can_reopen: not open? and Tasks.may_reopen?(task, user, r),
      editing: false,
      show_picker: false
    )
  end

  # After a close/reopen the task may have vanished (deleted meanwhile, or no
  # longer visible): leave for the list instead of crashing on nil.
  defp reload(socket, id) do
    %{current_company: com, current_user: user} = socket.assigns

    case Tasks.get_task(id, com, user) do
      %CompanyTask{} = task -> assign_task(socket, task)
      nil -> deny(socket, gettext("Task not found."))
    end
  end

  @impl true
  def handle_event("edit", _, socket) do
    if socket.assigns.can_edit do
      {:noreply, assign(socket, editing: true)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("toggle_picker", _, socket),
    do: {:noreply, assign(socket, show_picker: !socket.assigns.show_picker)}

  def handle_event("remove_link", %{"id" => link_id}, socket) do
    %{task: task, current_company: com, current_user: user} = socket.assigns

    # A malformed id from the client must not reach the binary_id query.
    case Ecto.UUID.cast(link_id) do
      {:ok, uuid} ->
        socket =
          case Tasks.remove_link(task, uuid, com, user) do
            {:error, :closed} ->
              put_flash(
                socket,
                :warn,
                gettext("A closed task cannot be edited — reopen it first.")
              )

            _ ->
              socket
          end

        links = Tasks.list_links(task, com, user)
        {:noreply, assign(socket, links: links, link_count: length(links))}

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event("delete", _, socket) do
    %{task: task, current_company: com, current_user: user} = socket.assigns

    case Tasks.delete_task(task, com, user) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Task deleted."))
         |> push_navigate(to: ~p"/companies/#{com.id}/tasks")}

      {:error, :closed} ->
        {:noreply,
         socket
         |> reload(task.id)
         |> put_flash(:warn, gettext("A closed task cannot be edited — reopen it first."))}

      _ ->
        {:noreply, put_flash(socket, :warn, gettext("Not Authorise."))}
    end
  end

  def handle_event("open_close", %{"kind" => kind}, socket) do
    task = socket.assigns.task

    next_due =
      task.recur_unit && Tasks.next_due_date(task.due_date, task.recur_unit, task.recur_every)

    kind = if kind == "skip", do: :skipped, else: :done
    {:noreply, assign(socket, closing: %{task: task, kind: kind, next_due: next_due})}
  end

  def handle_event("cancel_close", _, socket), do: {:noreply, assign(socket, closing: nil)}

  def handle_event("confirm_close", _, %{assigns: %{closing: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("confirm_close", %{"close" => %{"note" => note}}, socket) do
    %{task: task, closing: %{kind: kind}, current_company: com, current_user: user} =
      socket.assigns

    socket = assign(socket, closing: nil)

    case Tasks.close_task(task, kind, note, com, user) do
      {:ok, %{next: %CompanyTask{} = next}} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Task closed. This is the next cycle."))
         |> push_navigate(to: ~p"/companies/#{com.id}/tasks/#{next.id}")}

      {:ok, %{closed: closed}} ->
        {:noreply, socket |> reload(closed.id) |> put_flash(:info, gettext("Task closed."))}

      {:error, :already_closed} ->
        {:noreply,
         socket
         |> reload(task.id)
         |> put_flash(:warn, gettext("Someone already closed this task."))}

      _ ->
        {:noreply, put_flash(socket, :warn, gettext("Not Authorise."))}
    end
  end

  def handle_event("reopen", _, socket) do
    %{task: task, current_company: com, current_user: user} = socket.assigns

    case Tasks.reopen_task(task, com, user) do
      {:ok, %{reopened: r, next_kept: kept}} ->
        msg =
          if kept,
            do: gettext("Task reopened. The next cycle was already worked on, so it stays."),
            else: gettext("Task reopened.")

        {:noreply, socket |> assign_task(r) |> put_flash(:info, msg)}

      {:error, :open} ->
        {:noreply,
         socket |> reload(task.id) |> put_flash(:warn, gettext("This task is already open."))}

      _ ->
        {:noreply, put_flash(socket, :warn, gettext("Not Authorise."))}
    end
  end

  # The write box (TaskFormComponent, id "task") finished or changed links.
  @impl true
  def handle_info({:task_form, "task", {:saved, :new, task}}, socket) do
    {:noreply,
     socket
     |> put_flash(:info, gettext("Task saved."))
     |> push_navigate(to: ~p"/companies/#{socket.assigns.current_company.id}/tasks/#{task.id}")}
  end

  def handle_info({:task_form, "task", {:saved, :edit, task}}, socket),
    do: {:noreply, socket |> assign_task(task) |> put_flash(:info, gettext("Task saved."))}

  # Links on a saved task apply at once, so a cancelled edit still reloads.
  def handle_info({:task_form, "task", :cancelled}, socket),
    do: {:noreply, reload(socket, socket.assigns.task.id)}

  def handle_info({:task_form, "task", :links_changed}, socket) do
    %{task: task, current_company: com, current_user: user} = socket.assigns
    links = Tasks.list_links(task, com, user)
    {:noreply, assign(socket, links: links, link_count: length(links))}
  end

  # The post view's own ＋ link a record (edit mode uses the write box's picker).
  def handle_info({:record_picked, "record-picker", picked}, socket) do
    socket = assign(socket, show_picker: false)
    %{task: task, current_company: com, current_user: user} = socket.assigns

    case Tasks.add_link(task, picked.type, picked.id, com, user) do
      {:ok, _} ->
        links = Tasks.list_links(task, com, user)
        {:noreply, assign(socket, links: links, link_count: length(links))}

      {:error, %Ecto.Changeset{errors: [{_f, error} | _]}} ->
        {:noreply, put_flash(socket, :warn, FullCircleWeb.CoreComponents.translate_error(error))}

      {:error, :closed} ->
        {:noreply,
         put_flash(socket, :warn, gettext("A closed task cannot be edited — reopen it first."))}

      _ ->
        {:noreply, put_flash(socket, :warn, gettext("Could not link that record."))}
    end
  end

  # A record_chip target: saved links carry a resolved target (list_links);
  # links queued on a new task or copy are the picker's %{type, id, title}.
  defp chip_target(%{target: target}, _company), do: target

  defp chip_target(%{type: type, id: id, title: title}, company),
    do: {:ok, %{title: title, url: Linkable.url(type, id, company)}}

  defp cycle_notes(counts, id) do
    case Map.get(counts, id, 0) do
      0 -> nil
      n -> "📝 #{n}"
    end
  end

  # Same outline pill as ✎ Edit. Color is the only difference. These must not
  # use the `.button` class: its unlayered padding would win over these utilities.
  defp pill(color) do
    "rounded-full border px-3 py-0.5 text-sm #{pill_color(color)}"
  end

  defp pill_color("gray"),
    do: "border-gray-300 hover:bg-gray-100 dark:border-gray-600 dark:hover:bg-gray-700/60"

  defp pill_color("zinc"),
    do: "border-zinc-400 text-zinc-800 hover:bg-zinc-100 dark:hover:bg-zinc-800"

  defp pill_color("amber"),
    do: "border-amber-500 text-amber-700 hover:bg-amber-100 dark:hover:bg-amber-900"

  defp pill_color("red"),
    do: "border-red-600 text-red-700 hover:bg-red-50 dark:hover:bg-red-900"

  defp pill_color("green"),
    do: "border-green-600 text-green-700 hover:bg-green-50 dark:hover:bg-green-900"

  # Done and Skip share one box. The fill differs because finishing and
  # skipping are different actions. Neither uses the Edit outline.
  defp close_pill(kind) do
    "inline-flex w-20 shrink-0 items-center justify-center rounded-full border px-3 py-0.5 text-sm font-medium #{close_style(kind)}"
  end

  defp close_style("done"),
    do: "border-green-700 bg-green-600 text-white hover:bg-green-700"

  defp close_style("skip"),
    do: "border-gray-300 bg-gray-200 text-gray-800 hover:bg-gray-300"

  # The post's buttons (the write box has its own Save/Cancel). Counts stay on
  # the left. Copy/Back/Delete/Edit are one group; Done/Skip/Reopen the other.
  # `gap-7` is only between those two groups.
  defp action_row(assigns) do
    ~H"""
    <div class={["flex flex-wrap items-center gap-7", @class]}>
      <div class="flex flex-wrap items-center gap-2">
        <.link
          :if={@live_action == :edit and @rights.create}
          navigate={~p"/companies/#{@company.id}/tasks/#{@task.id}/copy"}
          id="copy-task"
          class={pill("gray")}
        >
          {gettext("Copy")}
        </.link>
        <.link
          id="back-task"
          navigate={~p"/companies/#{@company.id}/tasks"}
          class={pill("amber")}
        >
          {gettext("Back")}
        </.link>
        <button
          :if={@can_edit and @live_action == :edit}
          type="button"
          id="delete-task"
          phx-click="delete"
          data-confirm={gettext("Delete this task? A repeating task stops repeating.")}
          class={pill("red")}
        >
          {gettext("Delete")}
        </button>
        <button :if={@show_edit} type="button" id="edit-task" phx-click="edit" class={pill("gray")}>
          ✎ {gettext("Edit")}
        </button>
      </div>
      <div
        :if={@can_close or @can_reopen}
        class="flex flex-wrap items-center gap-2"
      >
        <button
          :if={@can_close}
          type="button"
          id="done-task"
          phx-click="open_close"
          phx-value-kind="done"
          class={close_pill("done")}
        >
          ✓ {gettext("Done")}
        </button>
        <button
          :if={@can_close}
          type="button"
          id="skip-task"
          phx-click="open_close"
          phx-value-kind="skip"
          class={close_pill("skip")}
        >
          {gettext("Skip")}
        </button>
        <button
          :if={@can_reopen}
          type="button"
          id="reopen-task"
          phx-click="reopen"
          class={pill("amber")}
        >
          {gettext("Reopen")}
        </button>
      </div>
    </div>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-[41.4rem] border-x border-gray-200 bg-white dark:border-gray-700 dark:bg-gray-900">
      <div class="h-1 bg-amber-500"></div>
      <div class="flex items-center gap-4 border-b border-gray-200 px-4 py-2 dark:border-gray-700">
        <.link
          id="back-to-tasks"
          navigate={~p"/companies/#{@current_company.id}/tasks"}
          class="rounded-full px-2 text-xl hover:bg-gray-100 dark:hover:bg-gray-700/60"
          title={gettext("Back")}
        >
          ←
        </.link>
        <span class="text-lg font-bold">{@page_title}</span>
      </div>

      <%= if @live_action in [:new, :copy] or @editing do %>
        <div class="border-b border-gray-200 px-4 py-3 dark:border-gray-700">
          <.live_component
            module={TaskFormComponent}
            id="task"
            mode={if @live_action == :edit, do: :edit, else: :new}
            task={@task}
            initial_links={@links}
            cancellable={@editing}
            current_company={@current_company}
            current_user={@current_user}
          >
            <:footer :if={@live_action == :edit}>
              <span title={gettext("Progress")}>📝 {@note_count}</span>
              <span>🔗 {@link_count}</span>
            </:footer>
            <:actions :if={not @editing}>
              <.link
                id="back-task"
                navigate={~p"/companies/#{@current_company.id}/tasks"}
                class={pill("amber")}
              >
                {gettext("Back")}
              </.link>
            </:actions>
          </.live_component>
        </div>
      <% else %>
        <article id="task-post" class="border-b border-gray-200 px-4 py-3 dark:border-gray-700">
          <div class="flex gap-3">
            <.due_tile
              task={@task}
              group={Tasks.group_of(@task, @today)}
              today={@today}
              company={@current_company}
            />
            <div class="min-w-0 flex-1">
              <div class="text-sm text-gray-500 dark:text-gray-400">{people_line(@task)}</div>
              <h1 class="text-xl font-bold">{@task.title}</h1>
              <%!-- phx-no-format: pre-wrap would show the template's indentation. --%>
              <p
                :if={@task.descriptions not in [nil, ""]}
                phx-no-format
                class="mt-1 whitespace-pre-wrap text-base text-gray-800 dark:text-gray-200"
              >{@task.descriptions}</p>
              <p
                :if={@task.documents_needed not in [nil, ""]}
                class="mt-1 text-sm text-amber-800 dark:text-amber-200"
              >
                {gettext("Task expects:")} {@task.documents_needed}
              </p>
              <div class="mt-2 flex flex-wrap items-center gap-1">
                <.record_chip
                  :for={l <- @links}
                  type={l.type}
                  target={chip_target(l, @current_company)}
                >
                  <button
                    :if={@can_edit}
                    type="button"
                    id={"remove-link-#{l.link_id}"}
                    phx-click="remove_link"
                    phx-value-id={l.link_id}
                    title={gettext("Remove")}
                    class="shrink-0"
                  >
                    ✕
                  </button>
                </.record_chip>
                <button
                  :if={@can_edit}
                  type="button"
                  id="open-picker"
                  phx-click="toggle_picker"
                  class="rounded-full border border-dashed border-slate-400 px-2 text-xs text-slate-600 dark:text-slate-300"
                >
                  ＋ {gettext("link a record")}
                </button>
              </div>
              <div class="mt-2 text-sm text-gray-500 dark:text-gray-400">{rhythm(@task)}</div>
              <div class="mt-2 flex flex-wrap items-center gap-3 text-sm text-gray-500 dark:text-gray-400">
                <span title={gettext("Progress")}>📝 {@note_count}</span>
                <span>🔗 {@link_count}</span>
                <.action_row
                  class="ml-auto"
                  show_edit={@can_edit}
                  can_edit={@can_edit}
                  can_close={@can_close}
                  can_reopen={@can_reopen}
                  live_action={@live_action}
                  rights={@rights}
                  task={@task}
                  company={@current_company}
                />
              </div>
            </div>
          </div>
          <div :if={@show_picker} class="mt-3">
            <.live_component
              module={RecordPickerComponent}
              id="record-picker"
              label={gettext("Link a record")}
              current_company={@current_company}
              current_user={@current_user}
            />
          </div>
        </article>
      <% end %>

      <.live_component
        :if={@live_action == :edit}
        module={FullCircleWeb.NoteLive.NotesPanelComponent}
        id="task-notes"
        record_type="Task"
        record_id={@task.id}
        current_company={@current_company}
        current_user={@current_user}
        flush
      />

      <section
        :if={@cycles != []}
        id="past-cycles"
        class="border-t border-gray-200 px-4 py-3 text-sm dark:border-gray-700"
      >
        <h2 class="mb-1 font-semibold">🕘 {gettext("Other cycles")}</h2>
        <.link
          :for={c <- @cycles}
          id={"cycle-#{c.id}"}
          navigate={~p"/companies/#{@current_company.id}/tasks/#{c.id}"}
          class="flex gap-3 border-b border-slate-200 py-1 last:border-0 hover:bg-sky-50/70 dark:border-gray-700 dark:hover:bg-gray-700/60"
        >
          <span class="w-24 tabular-nums">{c.due_date && FullCircleWeb.Helpers.format_date(c.due_date)}</span>
          <span class="w-20">
            {case c.status do
              "done" -> gettext("Done")
              "skipped" -> gettext("Skipped")
              _ -> gettext("Open")
            end}
          </span>
          <span class="flex-1 truncate text-slate-500 dark:text-slate-400">
            {c.closed_by && c.closed_by.email}
            {c.closed_at && FullCircleWeb.Helpers.format_datetime(c.closed_at, @current_company)}
          </span>
          <span class="w-12 shrink-0 text-right tabular-nums text-xs text-slate-500 dark:text-slate-400">
            {cycle_notes(@cycle_counts, c.id)}
          </span>
        </.link>
      </section>

      <.close_dialog :if={@closing} closing={@closing} />
    </div>
    """
  end
end
