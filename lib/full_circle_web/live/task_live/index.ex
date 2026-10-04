defmodule FullCircleWeb.TaskLive.Index do
  @moduledoc """
  Tasks column: the same narrow feed as Notes, with an amber top line and a
  due tile instead of a person avatar. Open tasks are grouped Overdue · Due
  soon · Upcoming · Someday. Group headings are stream items of their own.
  """
  use FullCircleWeb, :live_view

  import FullCircleWeb.TaskComponents

  alias FullCircle.Tasks

  @per_page 30

  @impl true
  def mount(_params, _session, socket) do
    %{current_company: com, current_user: user} = socket.assigns

    if FullCircle.Authorization.can?(user, :view_tasks, com) do
      if connected?(socket), do: Phoenix.PubSub.subscribe(FullCircle.PubSub, Tasks.topic(com.id))

      {:ok,
       socket
       |> assign(
         page_title: gettext("Tasks"),
         rights: Tasks.rights(com, user),
         closing: nil,
         compose_title: "",
         compose_due: "",
         show_due: false,
         compose_private: false
       )
       |> stream_configure(:rows, dom_id: &"tasks-#{&1.id}")}
    else
      {:ok,
       socket
       |> put_flash(:warn, gettext("You cannot open tasks."))
       |> push_navigate(to: ~p"/companies/#{com.id}/dashboard")}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    s = params["search"] || %{}

    search = %{
      "scope" => if(s["scope"] == "mine", do: "mine", else: "all"),
      "state" => if(s["state"] == "closed", do: "closed", else: "open"),
      "terms" => s["terms"] || ""
    }

    {:noreply, socket |> assign(search: search) |> load(true, 1)}
  end

  defp load(socket, reset, page) do
    %{current_company: com, current_user: user, search: search} = socket.assigns
    today = Tasks.today(com)
    rows = Tasks.list_tasks(com, user, search, page: page, per_page: @per_page, today: today)
    last_group = if reset, do: nil, else: socket.assigns[:last_group]

    {items, last_group} =
      Enum.flat_map_reduce(rows, last_group, fn row, prev ->
        if row.group != prev and search["state"] == "open",
          do: {[%{id: "group-#{row.group}", heading: row.group}, row], row.group},
          else: {[row], prev}
      end)

    socket
    |> assign(page: page, today: today, last_group: last_group)
    |> assign(counts: Tasks.badge_counts(com, user, today))
    |> assign(end_of_timeline?: length(rows) < @per_page)
    |> stream(:rows, items, reset: reset)
  end

  @impl true
  def handle_event("search", %{"search" => s}, socket) do
    {:noreply, push_patch(socket, to: index_path(socket, Map.merge(socket.assigns.search, s)))}
  end

  def handle_event("scope", %{"scope" => scope}, socket) do
    {:noreply,
     push_patch(socket, to: index_path(socket, Map.put(socket.assigns.search, "scope", scope)))}
  end

  def handle_event("compose", %{"compose" => p}, socket) do
    {:noreply,
     assign(socket,
       compose_title: p["title"] || "",
       compose_due: p["due_date"] || socket.assigns.compose_due
     )}
  end

  def handle_event("toggle_due", _, socket) do
    show = not socket.assigns.show_due

    {:noreply,
     assign(socket,
       show_due: show,
       compose_due: if(show, do: socket.assigns.compose_due, else: "")
     )}
  end

  def handle_event("toggle_private", _, socket) do
    {:noreply, assign(socket, compose_private: not socket.assigns.compose_private)}
  end

  def handle_event("add", %{"compose" => p}, socket) do
    %{current_company: com, current_user: user} = socket.assigns
    title = String.trim(p["title"] || "")

    attrs = %{
      "title" => title,
      "due_date" => if(socket.assigns.show_due, do: blank(p["due_date"]), else: nil),
      "visibility" =>
        if(socket.assigns.compose_private,
          do: FullCircle.Notes.Note.private_visibility(),
          else: nil
        )
    }

    case Tasks.create_task(attrs, com, user) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(compose_title: "", compose_due: "", show_due: false, compose_private: false)
         |> put_flash(:info, gettext("Task saved."))
         |> load(true, 1)}

      {:error, %Ecto.Changeset{errors: [{_field, err} | _]}} ->
        {:noreply, put_flash(socket, :warn, FullCircleWeb.CoreComponents.translate_error(err))}

      _ ->
        {:noreply, put_flash(socket, :warn, gettext("Could not save the task."))}
    end
  end

  def handle_event("next-page", _, socket),
    do: {:noreply, load(socket, false, socket.assigns.page + 1)}

  def handle_event("open_close", %{"id" => id, "kind" => kind}, socket) do
    %{current_company: com, current_user: user} = socket.assigns

    case Tasks.get_task(id, com, user) do
      nil ->
        {:noreply, put_flash(socket, :warn, gettext("Task not found."))}

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
        {:noreply, socket |> put_flash(:info, gettext("Task closed.")) |> load(true, 1)}

      {:error, :already_closed} ->
        {:noreply,
         socket |> put_flash(:warn, gettext("Someone already closed this task.")) |> load(true, 1)}

      _ ->
        {:noreply, put_flash(socket, :warn, gettext("Not Authorise."))}
    end
  end

  # Another user's change: reload so groups and the latest notes stay true.
  @impl true
  def handle_info({:tasks_changed, _}, socket), do: {:noreply, load(socket, true, 1)}

  defp index_path(socket, search) do
    ~p"/companies/#{socket.assigns.current_company.id}/tasks?#{%{search: search}}"
  end

  defp blank(nil), do: nil
  defp blank(""), do: nil
  defp blank(value), do: value

  defp draft_due(due) do
    case Date.from_iso8601(due || "") do
      {:ok, date} -> date
      _ -> nil
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-[41.4rem] border-x border-gray-200 bg-white dark:border-gray-700 dark:bg-gray-900">
      <div class="h-1 bg-amber-500"></div>
      <div class="flex border-b border-gray-200 dark:border-gray-700">
        <button
          :for={
            {scope, label, count} <- [
              {"all", gettext("All"), @counts.all},
              {"mine", gettext("Mine"), @counts.mine}
            ]
          }
          id={"tab-#{scope}"}
          type="button"
          phx-click="scope"
          phx-value-scope={scope}
          class={[
            "flex-1 py-3 text-sm font-bold hover:bg-gray-50 dark:hover:bg-gray-700/60",
            if(@search["scope"] == scope,
              do: "text-gray-900 shadow-[inset_0_-3px_0_#f59e0b] dark:text-gray-100",
              else: "text-gray-500"
            )
          ]}
        >
          {label}<span
            :if={count > 0}
            id={"tab-#{scope}-count"}
            class="ml-1 rounded-full bg-rose-600 px-1.5 text-xs font-bold text-white"
          >{count}</span>
        </button>
      </div>

      <div :if={@rights.create} class="border-b border-gray-200 px-4 py-3 dark:border-gray-700">
        <.form
          for={%{}}
          as={:compose}
          id="task-compose"
          phx-change="compose"
          phx-submit="add"
          autocomplete="off"
        >
          <div class="flex gap-3">
            <button
              type="button"
              phx-click="toggle_due"
              class="flex h-11 w-11 shrink-0 flex-col items-center justify-center rounded-lg bg-amber-800 text-[11px] font-bold leading-none text-amber-50"
            >
              <%= if date = draft_due(@compose_due) do %>
                <span class="text-sm">{date.day}</span>
                <span class="mt-0.5 text-[10px] font-medium">{Calendar.strftime(date, "%b")}</span>
              <% else %>
                {gettext("Due")}
              <% end %>
            </button>
            <div class="min-w-0 flex-1">
              <input
                type="text"
                name="compose[title]"
                value={@compose_title}
                placeholder={gettext("Add a task…")}
                class="w-full border-0 bg-transparent p-0 text-sm placeholder:text-gray-500 focus:ring-0 dark:bg-transparent"
              />
              <input
                :if={@show_due}
                type="date"
                name="compose[due_date]"
                value={@compose_due}
                class="mt-2 rounded border-gray-300 py-0.5 text-xs dark:border-gray-600 dark:bg-gray-800"
              />
              <div class="mt-2 flex items-center gap-2">
                <button
                  type="button"
                  phx-click="toggle_due"
                  class="rounded-full border border-gray-300 px-2 py-0.5 text-xs text-gray-600 dark:border-gray-600 dark:text-gray-300"
                >
                  {gettext("due…")}
                </button>
                <button
                  type="button"
                  phx-click="toggle_private"
                  class={[
                    "rounded-full border px-2 py-0.5 text-xs",
                    if(@compose_private,
                      do:
                        "border-rose-400 bg-rose-100 text-rose-800 dark:border-rose-700 dark:bg-rose-950 dark:text-rose-200",
                      else: "border-gray-300 text-gray-600 dark:border-gray-600 dark:text-gray-300"
                    )
                  ]}
                >
                  {if @compose_private, do: gettext("Private"), else: gettext("Everyone")}
                </button>
                <.link
                  id="new_task"
                  navigate={~p"/companies/#{@current_company.id}/tasks/new"}
                  class="text-xs text-gray-500 hover:underline dark:text-gray-400"
                >
                  {gettext("Full form")}
                </.link>
                <button
                  type="submit"
                  class="ml-auto rounded-full bg-amber-500 px-3 py-0.5 text-sm font-bold text-white hover:bg-amber-600"
                >
                  {gettext("Add")}
                </button>
              </div>
            </div>
          </div>
        </.form>
      </div>

      <div class="border-b border-gray-200 px-4 py-2 dark:border-gray-700">
        <div class="flex items-center gap-2">
          <form id="search-form" phx-change="search" phx-submit="search" class="flex-1">
            <input
              type="search"
              name="search[terms]"
              value={@search["terms"]}
              phx-debounce="300"
              autocomplete="off"
              placeholder={"🔍 " <> gettext("Search tasks")}
              class="w-full rounded-full border-0 bg-gray-100 px-4 py-1.5 text-sm focus:ring-1 focus:ring-amber-400 dark:bg-gray-800"
            />
          </form>
          <form id="state-form" phx-change="search">
            <select
              name="search[state]"
              class="rounded-full border-gray-300 py-1 text-xs dark:border-gray-600 dark:bg-gray-800"
            >
              <option value="open" selected={@search["state"] == "open"}>{gettext("Open")}</option>
              <option value="closed" selected={@search["state"] == "closed"}>
                {gettext("Done & skipped")}
              </option>
            </select>
          </form>
        </div>
      </div>

      <div id="tasks_list" phx-update="stream">
        <div id="tasks-empty" class="hidden only:block px-4 py-8 text-center text-sm text-gray-500">
          {gettext("Nothing here.")}
        </div>
        <%= for {dom_id, item} <- @streams.rows do %>
          <%= if item[:heading] do %>
            <.group_heading id={dom_id} group={item.heading} />
          <% else %>
            <.task_row
              id={dom_id}
              item={item}
              today={@today}
              company={@current_company}
            >
              <:actions :if={
                item.task.status == "open" and Tasks.may_close?(item.task, @current_user, @rights)
              }>
                <.close_buttons task_id={item.task.id} />
              </:actions>
            </.task_row>
          <% end %>
        <% end %>
      </div>
      <.infinite_scroll_footer ended={@end_of_timeline?} />
      <.close_dialog :if={@closing} closing={@closing} />
    </div>
    """
  end
end
