defmodule FullCircleWeb.TaskLive.Form do
  @moduledoc """
  The task's one page: create, read and edit (like notes, no show page).
  Below the form: progress notes (the notes panel, Private by default) and the
  series' past cycles. The assignee gets the fields read-only plus Done/Skip.
  """
  use FullCircleWeb, :live_view

  import FullCircleWeb.NoteComponents
  import FullCircleWeb.TaskComponents, only: [close_dialog: 1]

  alias FullCircle.{Linkable, Notes, Tasks}
  alias FullCircle.Tasks.CompanyTask
  alias FullCircleWeb.NoteLive.RecordPickerComponent

  @impl true
  def mount(params, _session, socket) do
    %{current_company: com, current_user: user} = socket.assigns

    socket =
      assign(socket,
        show_picker: false,
        params: %{},
        closing: nil,
        users: Tasks.assignable_users(com),
        rights: Tasks.rights(com, user)
      )

    case socket.assigns.live_action do
      :new ->
        if socket.assigns.rights.create,
          do: {:ok, mount_new(socket)},
          else: {:ok, deny(socket, gettext("You cannot create tasks."))}

      :copy ->
        with {:rights, true} <- {:rights, socket.assigns.rights.create},
             {:task, %CompanyTask{} = src} <-
               {:task, Tasks.get_task(params["task_id"], com, user)} do
          {:ok, mount_new(socket, copy_of(src, socket.assigns.users), gettext("Copy Task"))}
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

  defp mount_new(socket, prefill \\ %CompanyTask{}, title \\ gettext("New Task")) do
    assign(socket,
      page_title: title,
      task: prefill,
      links: [],
      cycles: [],
      cycle_counts: %{},
      can_edit: true,
      can_close: false,
      can_reopen: false,
      form: to_form(Tasks.change_task(prefill), as: :task)
    )
  end

  defp assign_task(socket, task) do
    %{current_company: com, current_user: user, rights: r} = socket.assigns
    open? = task.status == "open"
    cycles = Tasks.series_cycles(task, com, user)

    assign(socket,
      page_title: task.title,
      task: task,
      params: %{},
      links: Tasks.list_links(task, com, user),
      cycles: cycles,
      cycle_counts: Notes.count_by_records(com, user, "Task", Enum.map(cycles, & &1.id)),
      can_edit: open? and Tasks.may_edit?(task, user, r),
      can_close: open? and Tasks.may_close?(task, user, r),
      can_reopen: not open? and Tasks.may_reopen?(task, user, r),
      form: to_form(Tasks.change_task(task), as: :task)
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

  defp change(socket, params) do
    cs = socket.assigns.task |> Tasks.change_task(params) |> Map.put(:action, :validate)
    assign(socket, form: to_form(cs, as: :task), params: params)
  end

  @impl true
  def handle_event("validate", %{"task" => params}, socket),
    do: {:noreply, change(socket, params)}

  def handle_event("visibility_everyone", _, socket),
    do: {:noreply, change(socket, Map.put(socket.assigns.params, "visibility", [""]))}

  def handle_event("visibility_private", _, socket) do
    params =
      Map.put(socket.assigns.params, "visibility", FullCircle.Notes.Note.private_visibility())

    {:noreply, change(socket, params)}
  end

  def handle_event("toggle_picker", _, socket),
    do: {:noreply, assign(socket, show_picker: !socket.assigns.show_picker)}

  def handle_event("remove_new_link", %{"id" => id}, socket),
    do: {:noreply, assign(socket, links: Enum.reject(socket.assigns.links, &(&1.id == id)))}

  def handle_event("remove_link", %{"id" => link_id}, socket) do
    %{task: task, current_company: com, current_user: user} = socket.assigns

    socket =
      case Tasks.remove_link(task, link_id, com, user) do
        {:error, :closed} ->
          put_flash(socket, :warn, gettext("A closed task cannot be edited — reopen it first."))

        _ ->
          socket
      end

    {:noreply, assign(socket, links: Tasks.list_links(task, com, user))}
  end

  def handle_event("save", %{"task" => params}, socket) do
    %{current_company: com, current_user: user} = socket.assigns

    case socket.assigns.live_action do
      new when new in [:new, :copy] ->
        links = Enum.map(socket.assigns.links, &%{"type" => &1.type, "id" => &1.id})

        case Tasks.create_task(Map.put(params, "links", links), com, user) do
          {:ok, task} ->
            {:noreply,
             socket
             |> put_flash(:info, gettext("Task saved."))
             |> push_navigate(to: ~p"/companies/#{com.id}/tasks/#{task.id}")}

          error ->
            {:noreply, save_error(socket, error, params)}
        end

      :edit ->
        case Tasks.update_task(socket.assigns.task, params, com, user) do
          {:ok, task} ->
            {:noreply, socket |> assign_task(task) |> put_flash(:info, gettext("Task saved."))}

          error ->
            {:noreply, save_error(socket, error, params)}
        end
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

  defp save_error(socket, {:error, :stale}, params) do
    socket
    |> assign(form: to_form(Tasks.change_task(socket.assigns.task, params), as: :task))
    |> put_flash(:warn, gettext("someone else changed this task — reload to see their version"))
  end

  defp save_error(socket, {:error, %Ecto.Changeset{} = cs}, _params),
    do: assign(socket, form: to_form(cs, as: :task))

  defp save_error(socket, {:error, {:link, :not_found}}, _params),
    do: put_flash(socket, :warn, gettext("A linked record no longer exists."))

  defp save_error(socket, {:error, :closed}, _params),
    do: put_flash(socket, :warn, gettext("A closed task cannot be edited — reopen it first."))

  defp save_error(socket, _, _params), do: put_flash(socket, :warn, gettext("Not Authorise."))

  @impl true
  def handle_info({:record_picked, "record-picker", picked}, socket) do
    socket = assign(socket, show_picker: false)
    %{task: task, current_company: com, current_user: user} = socket.assigns

    if socket.assigns.live_action in [:new, :copy] do
      {:noreply,
       assign(socket, links: Enum.uniq_by(socket.assigns.links ++ [picked], &{&1.type, &1.id}))}
    else
      case Tasks.add_link(task, picked.type, picked.id, com, user) do
        {:ok, _} ->
          {:noreply, assign(socket, links: Tasks.list_links(task, com, user))}

        {:error, %Ecto.Changeset{errors: [{_f, error} | _]}} ->
          {:noreply,
           put_flash(socket, :warn, FullCircleWeb.CoreComponents.translate_error(error))}

        {:error, :closed} ->
          {:noreply,
           put_flash(socket, :warn, gettext("A closed task cannot be edited — reopen it first."))}

        _ ->
          {:noreply, put_flash(socket, :warn, gettext("Could not link that record."))}
      end
    end
  end

  # A record_chip target: saved links carry a resolved target (list_links);
  # links queued on a new task or copy are the picker's %{type, id, title}.
  defp chip_target(%{target: target}, _company), do: target

  defp chip_target(%{type: type, id: id, title: title}, company),
    do: {:ok, %{title: title, url: Linkable.url(type, id, company)}}

  defp unit_options do
    [
      {gettext("Does not repeat"), ""},
      {gettext("days"), "day"},
      {gettext("weeks"), "week"},
      {gettext("months"), "month"},
      {gettext("years"), "year"}
    ]
  end

  defp selected_roles(form), do: Ecto.Changeset.get_field(form.source, :visibility) || []

  # A demoted assignee is no longer assignable, but must stay selected: an
  # option missing from the list would silently unassign them on save.
  defp assignee_options(users, %CompanyTask{assignee: %{id: id, email: email}}) do
    options = Enum.map(users, &{&1.email, &1.id})
    if Enum.any?(users, &(&1.id == id)), do: options, else: options ++ [{email, id}]
  end

  defp assignee_options(users, _task), do: Enum.map(users, &{&1.email, &1.id})

  defp cycle_notes(counts, id) do
    case Map.get(counts, id, 0) do
      0 -> nil
      n -> "📝 #{n}"
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto w-6/12 max-md:w-11/12">
      <div class="rounded-lg border border-slate-300 bg-white p-4 dark:border-gray-700 dark:bg-gray-900">
        <p class="w-full text-center text-2xl font-medium">{@page_title}</p>
        <p :if={@live_action == :edit} class="mb-2 text-center text-xs text-slate-500">
          {gettext("Created by")} {@task.creator.email}
          <span :if={@task.status != "open"}>
            · {if @task.status == "done", do: gettext("Done by"), else: gettext("Skipped by")}
            {@task.closed_by && @task.closed_by.email}
            {FullCircleWeb.Helpers.format_datetime(@task.closed_at, @current_company)}
          </span>
        </p>

        <.form for={@form} id="task-form" phx-change="validate" phx-submit="save" autocomplete="off">
          <.input field={@form[:title]} label={gettext("Title")} disabled={!@can_edit} />
          <.input
            field={@form[:descriptions]}
            type="textarea"
            rows="3"
            label={gettext("Description")}
            disabled={!@can_edit}
          />
          <div class="grid grid-cols-3 gap-2">
            <.input
              field={@form[:due_date]}
              type="date"
              label={gettext("Due date")}
              disabled={!@can_edit}
            />
            <.input
              field={@form[:recur_unit]}
              type="select"
              options={unit_options()}
              label={gettext("Repeats every")}
              disabled={!@can_edit}
            />
            <%!-- Always rendered (a hidden input would vanish from form tests and
                 phx-change); the changeset drops it when there is no unit. --%>
            <.input
              field={@form[:recur_every]}
              type="number"
              min="1"
              value={Ecto.Changeset.get_field(@form.source, :recur_every) || 1}
              label={gettext("Every")}
              disabled={!@can_edit}
            />
          </div>
          <div class="grid grid-cols-2 gap-2">
            <.input
              field={@form[:reminder_before_days]}
              type="number"
              min="0"
              label={gettext("Remind days before")}
              disabled={!@can_edit}
            />
            <.input
              field={@form[:assignee_id]}
              type="select"
              prompt={gettext("Unassigned")}
              options={assignee_options(@users, @task)}
              label={gettext("Assignee")}
              disabled={!@can_edit}
            />
          </div>
          <.input
            field={@form[:documents_needed]}
            type="textarea"
            rows="2"
            label={gettext("Documents needed (a reminder on Done)")}
            disabled={!@can_edit}
          />

          <div class="mt-3 flex flex-wrap items-center gap-1">
            <span
              class="mr-1 text-sm font-semibold"
              title={gettext("Admin, the creator and the assignee can always see it.")}
            >
              {gettext("Visible to")}
            </span>
            <.visibility_chips
              visibility={selected_roles(@form)}
              id_prefix="visibility"
              field_name="task[visibility][]"
              disabled={!@can_edit}
              private_title={gettext("Only admins, the creator and the assignee can see it.")}
            />
          </div>
          <.error :for={msg <- Enum.map(@form[:visibility].errors, &translate_error/1)}>{msg}</.error>

          <div class="mt-2 flex flex-wrap items-center gap-1">
            <span class="mr-1 text-sm font-semibold">{gettext("Linked records")}</span>
            <.record_chip :for={l <- @links} type={l.type} target={chip_target(l, @current_company)}>
              <button
                :if={@can_edit and @live_action == :edit}
                type="button"
                id={"remove-link-#{l.link_id}"}
                phx-click="remove_link"
                phx-value-id={l.link_id}
                title={gettext("Remove")}
                class="shrink-0"
              >
                ✕
              </button>
              <button
                :if={@live_action in [:new, :copy]}
                type="button"
                phx-click="remove_new_link"
                phx-value-id={l.id}
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

          <div class="mt-4 flex flex-wrap justify-center gap-2">
            <.button :if={@can_edit}>{gettext("Save")}</.button>
            <button
              :if={@can_close}
              type="button"
              id="done-task"
              phx-click="open_close"
              phx-value-kind="done"
              class="green button"
            >
              ✓ {gettext("Done")}
            </button>
            <button
              :if={@can_close}
              type="button"
              id="skip-task"
              phx-click="open_close"
              phx-value-kind="skip"
              class="gray button"
            >
              {gettext("Skip")}
            </button>
            <button
              :if={@can_reopen}
              type="button"
              id="reopen-task"
              phx-click="reopen"
              class="orange button"
            >
              {gettext("Reopen")}
            </button>
            <.link
              :if={@live_action == :edit and @rights.create}
              navigate={~p"/companies/#{@current_company.id}/tasks/#{@task.id}/copy"}
              id="copy-task"
              class="gray button"
            >
              {gettext("Copy")}
            </.link>
            <.link navigate={~p"/companies/#{@current_company.id}/tasks"} class="orange button">{gettext(
              "Back"
            )}</.link>
            <button
              :if={@can_edit and @live_action == :edit}
              type="button"
              id="delete-task"
              phx-click="delete"
              data-confirm={gettext("Delete this task? A repeating task stops repeating.")}
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
            label={gettext("Link a record")}
            current_company={@current_company}
            current_user={@current_user}
          />
        </div>
      </div>

      <.live_component
        :if={@live_action == :edit}
        module={FullCircleWeb.NoteLive.NotesPanelComponent}
        id="task-notes"
        record_type="Task"
        record_id={@task.id}
        current_company={@current_company}
        current_user={@current_user}
      />

      <section
        :if={@cycles != []}
        id="past-cycles"
        class="mx-auto mt-3 max-w-2xl rounded-lg border border-slate-200 p-3 text-sm dark:border-gray-700"
      >
        <h2 class="mb-1 font-semibold">🕘 {gettext("Other cycles")}</h2>
        <.link
          :for={c <- @cycles}
          id={"cycle-#{c.id}"}
          navigate={~p"/companies/#{@current_company.id}/tasks/#{c.id}"}
          class="flex gap-3 border-b border-slate-200 py-1 last:border-0 hover:bg-sky-50/70 dark:border-gray-700 dark:hover:bg-gray-800/70"
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
