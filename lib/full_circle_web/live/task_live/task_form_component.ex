defmodule FullCircleWeb.TaskLive.TaskFormComponent do
  @moduledoc """
  The one task write box: the task page's new / copy / edit mode and a
  record's tasks panel (＋ Task and ✎ Edit in place). It lays the task out as
  its post — due tile, people and Due line, title, description, Task expects,
  links, Repeat, visibility — with each line a field. It owns the form, saves
  through `Tasks`, and tells its host `{:saved, mode, task}`, `:cancelled` or
  `:links_changed` (see `notify`). Ids are prefixed with the component id.
  Contract: `.claude/skills/tasks.md`.
  """
  use FullCircleWeb, :live_component

  import FullCircleWeb.NoteComponents,
    only: [record_chip: 1, visibility_chips: 1, field_errors: 1, border: 2, show_errors?: 1]

  alias FullCircle.{Linkable, Tasks}
  alias FullCircle.Tasks.CompanyTask
  alias FullCircleWeb.NoteLive.RecordPickerComponent

  @defaults [
    mode: :new,
    initial_links: [],
    host: nil,
    cancellable: false,
    notify: :liveview,
    class: nil,
    footer: [],
    actions: []
  ]

  # A pick from this box's picker (RecordPickerComponent notify).
  @impl true
  def update(%{picked: {_picker_id, picked}}, socket), do: {:ok, pick(socket, picked)}

  # The box edits the task as it was when handed over, so a save after someone
  # else's comes back stale instead of overwriting it. Ordinary host re-renders
  # pass the same task and keep half-typed fields. Another task, or a newer
  # save of this one, starts afresh: LiveView keeps a removed component's state
  # if it is rendered again before the client confirms the removal (Save, then
  # ✎ Edit straight away), which would otherwise show the pre-save task.
  def update(assigns, socket) do
    first? = is_nil(socket.assigns[:form])

    retask? =
      not first? and Map.has_key?(assigns, :task) and
        task_key(assigns.task) != task_key(socket.assigns.task)

    socket =
      Enum.reduce(@defaults, assign(socket, assigns), fn {k, v}, s ->
        assign_new(s, k, fn -> v end)
      end)

    {:ok, if(first? or retask?, do: reset(socket), else: socket)}
  end

  defp task_key(%CompanyTask{id: id, lock_version: v}), do: {id, v}

  defp reset(socket) do
    %{task: task, current_company: com, current_user: user} = socket.assigns

    links =
      case socket.assigns.mode do
        :edit -> Tasks.list_links(task, com, user)
        _ -> socket.assigns.initial_links
      end

    assign(socket,
      users: Tasks.assignable_users(com),
      params: %{},
      links: links,
      show_picker: false,
      error: nil,
      form: to_form(Tasks.change_task(task), as: :task)
    )
  end

  defp change(socket, params) do
    cs = socket.assigns.task |> Tasks.change_task(params) |> Map.put(:action, :validate)
    assign(socket, form: to_form(cs, as: :task), params: params)
  end

  defp notify(%{assigns: %{notify: :liveview, id: id}}, event),
    do: send(self(), {:task_form, id, event})

  defp notify(%{assigns: %{notify: {module, cid}, id: id}}, event),
    do: send_update(module, id: cid, task_form: {id, event})

  # --- events ---------------------------------------------------------------

  @impl true
  # A message about the last action (a link, a stale save) goes once the
  # user edits again.
  def handle_event("validate", %{"task" => params}, socket),
    do: {:noreply, socket |> change(params) |> assign(error: nil)}

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
        error =
          case Tasks.remove_link(task, uuid, com, user) do
            {:error, :closed} -> closed_text()
            _ -> nil
          end

        notify(socket, :links_changed)
        {:noreply, assign(socket, links: Tasks.list_links(task, com, user), error: error)}

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event("cancel", _, socket) do
    notify(socket, :cancelled)
    {:noreply, socket}
  end

  def handle_event("save", %{"task" => params}, socket) do
    %{current_company: com, current_user: user, mode: mode, task: task} = socket.assigns

    result =
      case mode do
        :edit ->
          Tasks.update_task(task, params, com, user)

        _ ->
          links =
            Enum.map(socket.assigns.links, &%{"type" => &1.type, "id" => &1.id}) ++
              host_link(socket.assigns.host)

          Tasks.create_task(Map.put(params, "links", Enum.uniq(links)), com, user)
      end

    case result do
      {:ok, saved} ->
        notify(socket, {:saved, mode, saved})
        {:noreply, socket}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, assign(socket, form: to_form(cs, as: :task), params: params)}

      error ->
        {:noreply, socket |> change(params) |> assign(error: error_text(error))}
    end
  end

  # From a record's tasks panel the task is always linked to that record.
  defp host_link({type, id}), do: [%{"type" => type, "id" => id}]
  defp host_link(nil), do: []

  # The host record's own chip is left out, as the post leaves it out: it
  # would only point back at the page you are on, and ✕ would drop the task
  # from that page.
  defp shown_links(links, {type, id}), do: Enum.reject(links, &(&1.type == type and &1.id == id))
  defp shown_links(links, nil), do: links

  defp error_text({:error, :stale}),
    do: gettext("someone else changed this task — reload to see their version")

  defp error_text({:error, {:link, :not_found}}), do: gettext("A linked record no longer exists.")
  defp error_text({:error, :closed}), do: closed_text()
  defp error_text(_), do: gettext("Not Authorise.")

  defp closed_text, do: gettext("A closed task cannot be edited — reopen it first.")

  # A new task queues the pick; a saved one links it straight away.
  defp pick(socket, picked) do
    socket = assign(socket, show_picker: false)
    %{task: task, mode: mode, current_company: com, current_user: user} = socket.assigns

    if mode == :edit do
      case Tasks.add_link(task, picked.type, picked.id, com, user) do
        {:ok, _} ->
          notify(socket, :links_changed)
          assign(socket, links: Tasks.list_links(task, com, user), error: nil)

        {:error, %Ecto.Changeset{errors: [{_f, error} | _]}} ->
          assign(socket, error: FullCircleWeb.CoreComponents.translate_error(error))

        {:error, :closed} ->
          assign(socket, error: closed_text())

        _ ->
          assign(socket, error: gettext("Could not link that record."))
      end
    else
      assign(socket, links: Enum.uniq_by(socket.assigns.links ++ [picked], &{&1.type, &1.id}))
    end
  end

  # --- render ---------------------------------------------------------------

  # A record_chip target: saved links carry a resolved target (list_links);
  # links queued on a new task are the picker's %{type, id, title}.
  defp chip_target(%{target: target}, _company), do: target

  defp chip_target(%{type: type, id: id, title: title}, company),
    do: {:ok, %{title: title, url: Linkable.url(type, id, company)}}

  defp unit_options do
    [
      {gettext("never"), ""},
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

  defp email_name(%{email: email}) when is_binary(email), do: email |> String.split("@") |> hd()
  defp email_name(_), do: nil

  # "is needed to repeat" is the due date's error but is caused by picking a
  # repeat, so either one being touched shows it.
  defp due_shown?(form),
    do: show_errors?(form[:due_date]) or show_errors?(form[:recur_unit])

  @impl true
  def render(assigns) do
    ~H"""
    <div id={"#{@id}-box"} class={@class}>
      <.form
        for={@form}
        id={"#{@id}-form"}
        phx-change="validate"
        phx-submit="save"
        phx-target={@myself}
        autocomplete="off"
      >
        <%!-- No due tile: the form is all fields, the Due date among them. --%>
        <div class="text-sm text-gray-500 dark:text-gray-400">
          {email_name(@task.creator) || email_name(@current_user)} · {gettext("assigned to")}
          <select
            name="task[assignee_id]"
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
          · {gettext("Due")}
          <input
            type="date"
            name="task[due_date]"
            value={Phoenix.HTML.Form.normalize_value("date", @form[:due_date].value)}
            class={[
              "rounded-full bg-transparent px-2 py-0.5 text-sm dark:bg-gray-900",
              border(due_shown?(@form), "border-gray-400 dark:border-gray-600")
            ]}
          />
        </div>
        <.field_errors
          id={"#{@id}-due-errors"}
          fields={[
            {@form[:assignee_id], gettext("Assigned to")},
            {@form[:due_date], gettext("Due"), due_shown?(@form)}
          ]}
        />
        <input
          type="text"
          name="task[title]"
          value={@form[:title].value}
          placeholder={gettext("Title")}
          class={[
            "mt-1 w-full rounded-md border bg-transparent px-2 py-1 text-xl font-bold dark:bg-gray-900",
            border(@form[:title], "border-gray-400 dark:border-gray-600")
          ]}
        />
        <.field_errors id={"#{@id}-title-errors"} fields={[{@form[:title], nil}]} />
        <textarea
          name="task[descriptions]"
          rows="3"
          placeholder={gettext("Description")}
          class={[
            "mt-2 w-full resize-y rounded-md border bg-transparent px-2 py-1 text-base dark:bg-gray-900",
            border(@form[:descriptions], "border-gray-400 dark:border-gray-600")
          ]}
        >{Phoenix.HTML.Form.normalize_value("textarea", @form[:descriptions].value)}</textarea>
        <.field_errors id={"#{@id}-descriptions-errors"} fields={[{@form[:descriptions], nil}]} />
        <div class="mt-2 flex items-center gap-2 text-sm text-amber-800 dark:text-amber-200">
          <span class="shrink-0">{gettext("Task expects:")}</span>
          <input
            type="text"
            name="task[documents_needed]"
            value={@form[:documents_needed].value}
            class={[
              "min-w-0 flex-1 rounded-md border bg-transparent px-2 py-0.5 text-sm text-amber-900 dark:bg-gray-900 dark:text-amber-100",
              border(@form[:documents_needed], "border-gray-400 dark:border-gray-600")
            ]}
          />
        </div>
        <.field_errors id={"#{@id}-documents-errors"} fields={[{@form[:documents_needed], nil}]} />
        <div class="mt-2 flex flex-wrap items-center gap-1">
          <.record_chip
            :for={l <- shown_links(@links, @host)}
            type={l.type}
            target={chip_target(l, @current_company)}
          >
            <button
              :if={@mode == :edit}
              type="button"
              id={"remove-link-#{l.link_id}"}
              phx-click="remove_link"
              phx-value-id={l.link_id}
              phx-target={@myself}
              title={gettext("Remove")}
              class="shrink-0"
            >
              ✕
            </button>
            <button
              :if={@mode != :edit}
              type="button"
              phx-click="remove_new_link"
              phx-value-id={l.id}
              phx-target={@myself}
              title={gettext("Remove")}
              class="shrink-0"
            >
              ✕
            </button>
          </.record_chip>
          <button
            type="button"
            id={"#{@id}-open-picker"}
            phx-click="toggle_picker"
            phx-target={@myself}
            class="rounded-full border border-dashed border-slate-400 px-2 text-xs text-slate-600 dark:text-slate-300"
          >
            ＋ {gettext("link a record")}
          </button>
        </div>
        <p :if={@error} id={"#{@id}-error"} class="mt-0.5 text-xs text-rose-600 dark:text-rose-400">
          {@error}
        </p>
        <div class="mt-2 flex flex-wrap items-center gap-1 text-sm text-gray-500 dark:text-gray-400">
          {gettext("Repeat")}
          <%!-- Always rendered: a missing input would vanish from phx-change.
               Hidden while the task never repeats; the changeset drops it.
               `hidden` and `inline-flex` both set display, so never apply both. --%>
          <span class={
            if Ecto.Changeset.get_field(@form.source, :recur_unit) in [nil, ""],
              do: "hidden",
              else: "inline-flex items-center gap-1"
          }>
            {gettext("every")}
            <input
              type="number"
              name="task[recur_every]"
              min="1"
              value={Ecto.Changeset.get_field(@form.source, :recur_every) || 1}
              class={[
                "w-16 rounded-full bg-transparent px-2 py-0.5 text-center text-sm dark:bg-gray-900",
                border(@form[:recur_every], "border-gray-400 dark:border-gray-600")
              ]}
            />
          </span>
          <select
            name="task[recur_unit]"
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
          · {gettext("Remind days before")}
          <input
            type="number"
            name="task[reminder_before_days]"
            min="0"
            value={@form[:reminder_before_days].value}
            class={[
              "w-16 rounded-full bg-transparent px-2 py-0.5 text-center text-sm dark:bg-gray-900",
              border(@form[:reminder_before_days], "border-gray-400 dark:border-gray-600")
            ]}
          />
        </div>
        <.field_errors
          id={"#{@id}-repeat-errors"}
          fields={[
            {@form[:recur_unit], gettext("Repeat")},
            {@form[:recur_every], gettext("Repeat every")},
            {@form[:reminder_before_days], gettext("Remind days before")}
          ]}
        />
        <div
          class="mt-1 flex flex-wrap items-center gap-1"
          title={gettext("Admin, the creator and the assignee can always see it.")}
        >
          <.visibility_chips
            visibility={selected_roles(@form)}
            id_prefix={"#{@id}-visibility"}
            field_name="task[visibility][]"
            target={@myself}
            private_title={gettext("Only admins, the creator and the assignee can see it.")}
          />
        </div>
        <.field_errors id={"#{@id}-visibility-errors"} fields={[{@form[:visibility], nil, true}]} />
        <div class="mt-2 flex flex-wrap items-center gap-3 text-sm text-gray-500 dark:text-gray-400">
          {render_slot(@footer)}
          <span class="ml-auto flex flex-wrap items-center gap-2">
            <button
              type="submit"
              class="phx-submit-loading:opacity-75 rounded-full border border-zinc-400 px-3 py-0.5 text-sm text-zinc-800 hover:bg-zinc-100 dark:hover:bg-zinc-800"
            >
              {gettext("Save")}
            </button>
            <button
              :if={@cancellable}
              type="button"
              id={"#{@id}-cancel"}
              phx-click="cancel"
              phx-target={@myself}
              class="rounded-full border border-gray-300 px-3 py-0.5 text-sm hover:bg-gray-100 dark:border-gray-600 dark:hover:bg-gray-700/60"
            >
              {gettext("Cancel")}
            </button>
            {render_slot(@actions)}
          </span>
        </div>
      </.form>
      <div :if={@show_picker} class="mt-3">
        <.live_component
          module={RecordPickerComponent}
          id={"#{@id}-picker"}
          notify={{__MODULE__, @id}}
          label={gettext("Link a record")}
          current_company={@current_company}
          current_user={@current_user}
        />
      </div>
    </div>
    """
  end
end
