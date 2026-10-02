defmodule FullCircleWeb.TaskLive.Form do
  @moduledoc """
  The task's one page, a column 15% wider than Notes. An open task starts as a
  post; Edit, new and copy keep that post and turn the lines into fields.
  Progress notes copy the task's visibility. Past cycles sit under the post.
  """
  use FullCircleWeb, :live_view

  import FullCircleWeb.NoteComponents
  import FullCircleWeb.TaskComponents, only: [close_dialog: 1, due_tile: 1, repeat_label: 1]

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
      editing: false,
      form: to_form(Tasks.change_task(prefill), as: :task)
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
      params: %{},
      links: links,
      link_count: length(links),
      note_count: Map.get(note_counts, task.id, 0),
      cycles: cycles,
      cycle_counts: Map.delete(note_counts, task.id),
      can_edit: open? and Tasks.may_edit?(task, user, r),
      can_close: open? and Tasks.may_close?(task, user, r),
      can_reopen: not open? and Tasks.may_reopen?(task, user, r),
      editing: false,
      show_picker: false,
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

  def handle_event("edit", _, socket) do
    if socket.assigns.can_edit do
      {:noreply, assign(socket, editing: true)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("cancel_edit", _, socket) do
    %{task: task} = socket.assigns

    {:noreply,
     assign(socket,
       editing: false,
       params: %{},
       show_picker: false,
       form: to_form(Tasks.change_task(task), as: :task)
     )}
  end

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
          links = Tasks.list_links(task, com, user)
          {:noreply, assign(socket, links: links, link_count: length(links))}

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

  defp email_name(%{email: email}) when is_binary(email), do: email |> String.split("@") |> hd()
  defp email_name(_), do: nil

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

  defp people_line(task) do
    creator = email_name(task.creator)

    cond do
      task.status != "open" ->
        verb = if task.status == "done", do: gettext("Done by"), else: gettext("Skipped by")
        "#{creator} · #{verb} #{email_name(task.closed_by)}"

      task.assignee ->
        "#{creator} · " <> gettext("assigned to %{who}", who: email_name(task.assignee))

      true ->
        "#{creator} · " <> gettext("unassigned")
    end
  end

  defp rhythm(task) do
    [
      repeat_label(task) || gettext("does not repeat"),
      task.reminder_before_days && gettext("reminder %{n} days", n: task.reminder_before_days),
      visibility_label(task.visibility)
    ]
    |> Enum.reject(&(&1 in [nil, false]))
    |> Enum.join(" · ")
  end

  defp visibility_label(nil), do: gettext("Everyone")
  defp visibility_label(["admin"]), do: gettext("Private")
  defp visibility_label(roles) when is_list(roles), do: Enum.join(roles, ", ")

  # The due tile follows the fields being edited, not only the saved task.
  defp draft_task(form, task) do
    %{
      task
      | due_date: Ecto.Changeset.get_field(form.source, :due_date),
        reminder_before_days: Ecto.Changeset.get_field(form.source, :reminder_before_days),
        status: task.status || "open"
    }
  end

  defp field_errors(form) do
    ~w(title descriptions due_date recur_unit recur_every reminder_before_days assignee_id documents_needed visibility)a
    |> Enum.flat_map(fn field -> Enum.map(form[field].errors, &translate_error/1) end)
  end

  # Counts stay on the left. Save/Cancel/Copy/Back/Delete/Edit are one group;
  # Done/Skip/Reopen the other. `gap-7` is only between those two groups.
  defp action_row(assigns) do
    ~H"""
    <div class={["flex flex-wrap items-center gap-7", @class]}>
      <div class="flex flex-wrap items-center gap-2">
        <button
          :if={@save and @can_edit}
          type="submit"
          class={["phx-submit-loading:opacity-75", pill("zinc")]}
        >
          {gettext("Save")}
        </button>
        <button :if={@editing} type="button" phx-click="cancel_edit" class={pill("gray")}>
          {gettext("Cancel")}
        </button>
        <.link
          :if={@live_action == :edit and @rights.create and not @editing}
          navigate={~p"/companies/#{@company.id}/tasks/#{@task.id}/copy"}
          id="copy-task"
          class={pill("gray")}
        >
          {gettext("Copy")}
        </.link>
        <.link
          :if={not @editing}
          id="back-task"
          navigate={~p"/companies/#{@company.id}/tasks"}
          class={pill("amber")}
        >
          {gettext("Back")}
        </.link>
        <button
          :if={@can_edit and @live_action == :edit and not @editing}
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
        :if={not @editing and (@can_close or @can_reopen)}
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
          <.form for={@form} id="task-form" phx-change="validate" phx-submit="save" autocomplete="off">
            <div class="flex gap-3">
              <.due_tile
                task={draft_task(@form, @task)}
                group={Tasks.group_of(draft_task(@form, @task), @today)}
                today={@today}
                company={@current_company}
              />
              <div class="min-w-0 flex-1">
                <div class="text-sm text-gray-500 dark:text-gray-400">
                  {email_name(@task.creator) || email_name(@current_user)} · {gettext("assigned to")}
                  <select
                    name="task[assignee_id]"
                    disabled={!@can_edit}
                    class="rounded-full border-gray-400 bg-transparent py-0.5 text-sm dark:border-gray-600 dark:bg-gray-900"
                  >
                    <option value="">{gettext("Unassigned")}</option>
                    <option
                      :for={{email, id} <- assignee_options(@users, @task)}
                      value={id}
                      selected={to_string(id) == to_string(@form[:assignee_id].value || "")}
                    >
                      {email}
                    </option>
                  </select>
                </div>
                <input
                  type="text"
                  name="task[title]"
                  value={@form[:title].value}
                  placeholder={gettext("Title")}
                  disabled={!@can_edit}
                  class="mt-1 w-full rounded-md border border-gray-400 bg-transparent px-2 py-1 text-xl font-bold dark:border-gray-600 dark:bg-gray-900"
                />
                <textarea
                  name="task[descriptions]"
                  rows="3"
                  placeholder={gettext("Description")}
                  disabled={!@can_edit}
                  class="mt-2 w-full resize-y rounded-md border border-gray-400 bg-transparent px-2 py-1 text-sm dark:border-gray-600 dark:bg-gray-900"
                >{Phoenix.HTML.Form.normalize_value("textarea", @form[:descriptions].value)}</textarea>
                <div class="mt-2 flex items-center gap-2 text-sm text-amber-800 dark:text-amber-200">
                  <span class="shrink-0">{gettext("This task expects:")}</span>
                  <input
                    type="text"
                    name="task[documents_needed]"
                    value={@form[:documents_needed].value}
                    disabled={!@can_edit}
                    class="min-w-0 flex-1 rounded-md border border-gray-400 bg-transparent px-2 py-0.5 text-sm text-amber-900 dark:border-gray-600 dark:bg-gray-900 dark:text-amber-100"
                  />
                </div>
                <div class="mt-2 flex flex-wrap items-center gap-1">
                  <.record_chip
                    :for={l <- @links}
                    type={l.type}
                    target={chip_target(l, @current_company)}
                  >
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
                <div class="mt-2 flex flex-wrap items-center gap-1 text-sm text-gray-500 dark:text-gray-400">
                  {gettext("Due date")}
                  <input
                    type="date"
                    name="task[due_date]"
                    value={Phoenix.HTML.Form.normalize_value("date", @form[:due_date].value)}
                    disabled={!@can_edit}
                    class="rounded-full border-gray-400 bg-transparent px-2 py-0.5 text-sm dark:border-gray-600 dark:bg-gray-900"
                  /> ·
                  <select
                    name="task[recur_unit]"
                    disabled={!@can_edit}
                    class="rounded-full border-gray-400 bg-transparent py-0.5 text-sm dark:border-gray-600 dark:bg-gray-900"
                  >
                    <option
                      :for={{label, value} <- unit_options()}
                      value={value}
                      selected={to_string(value) == to_string(@form[:recur_unit].value || "")}
                    >
                      {label}
                    </option>
                  </select>
                  {gettext("Every")}
                  <%!-- Always rendered: a missing input would vanish from phx-change.
                       The changeset drops it when there is no unit. --%>
                  <input
                    type="number"
                    name="task[recur_every]"
                    min="1"
                    value={Ecto.Changeset.get_field(@form.source, :recur_every) || 1}
                    disabled={!@can_edit}
                    class="w-16 rounded-full border-gray-400 bg-transparent px-2 py-0.5 text-center text-sm dark:border-gray-600 dark:bg-gray-900"
                  /> · {gettext("Remind days before")}
                  <input
                    type="number"
                    name="task[reminder_before_days]"
                    min="0"
                    value={@form[:reminder_before_days].value}
                    disabled={!@can_edit}
                    class="w-16 rounded-full border-gray-400 bg-transparent px-2 py-0.5 text-center text-sm dark:border-gray-600 dark:bg-gray-900"
                  />
                </div>
                <div
                  class="mt-1 flex flex-wrap items-center gap-1"
                  title={gettext("Admin, the creator and the assignee can always see it.")}
                >
                  <.visibility_chips
                    visibility={selected_roles(@form)}
                    id_prefix="visibility"
                    field_name="task[visibility][]"
                    disabled={!@can_edit}
                    private_title={gettext("Only admins, the creator and the assignee can see it.")}
                  />
                </div>
                <.error :for={msg <- field_errors(@form)}>{msg}</.error>
                <div class="mt-2 flex flex-wrap items-center gap-3 text-sm text-gray-500 dark:text-gray-400">
                  <span :if={@live_action == :edit}>📝 {@note_count}</span>
                  <span :if={@live_action == :edit}>🔗 {@link_count}</span>
                  <.action_row
                    class="ml-auto"
                    save={true}
                    show_edit={false}
                    editing={@editing}
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
              <p
                :if={@task.descriptions not in [nil, ""]}
                class="mt-1 whitespace-pre-wrap text-sm text-gray-800 dark:text-gray-200"
              >
                {@task.descriptions}
              </p>
              <p
                :if={@task.documents_needed not in [nil, ""]}
                class="mt-1 text-sm text-amber-800 dark:text-amber-200"
              >
                {gettext("This task expects:")} {@task.documents_needed}
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
                <span>📝 {@note_count}</span>
                <span>🔗 {@link_count}</span>
                <.action_row
                  class="ml-auto"
                  save={false}
                  show_edit={@can_edit}
                  editing={false}
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
        heading={"📝 #{gettext("Progress notes")}"}
        current_company={@current_company}
        current_user={@current_user}
        class="mx-3 mb-3"
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
