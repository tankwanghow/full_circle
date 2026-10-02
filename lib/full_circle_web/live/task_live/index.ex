defmodule FullCircleWeb.TaskLive.Index do
  @moduledoc """
  Tasks list: open tasks grouped Overdue · Due soon · Upcoming · Someday, or
  closed ones newest first. One line per task (decluttered-index contract);
  group headings are stream items of their own.
  """
  use FullCircleWeb, :live_view

  import FullCircleWeb.ListComponents
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
       |> assign(page_title: gettext("Tasks"), rights: Tasks.rights(com, user), closing: nil)
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
      "scope" => if(s["scope"] == "all", do: "all", else: "mine"),
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
    |> assign(end_of_timeline?: length(rows) < @per_page)
    |> stream(:rows, items, reset: reset)
  end

  @impl true
  def handle_event("search", %{"search" => s}, socket) do
    {:noreply,
     push_patch(socket,
       to: ~p"/companies/#{socket.assigns.current_company.id}/tasks?#{%{search: s}}"
     )}
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

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto w-11/12 max-w-[96rem]">
      <.form for={%{}} as={:search} id="search-form" phx-submit="search" autocomplete="off">
        <.list_bar title={@page_title}>
          <div class="grow min-w-56">
            <.filter_label>{gettext("Search")}</.filter_label>
            <.input
              id="search_terms"
              name="search[terms]"
              type="search"
              value={@search["terms"]}
              placeholder={gettext("title, description or assignee…")}
            />
          </div>
          <div class="w-28">
            <.filter_label>{gettext("Whose")}</.filter_label>
            <.input
              id="search_scope"
              name="search[scope]"
              type="select"
              options={[{gettext("Mine"), "mine"}, {gettext("All"), "all"}]}
              value={@search["scope"]}
            />
          </div>
          <div class="w-36">
            <.filter_label>{gettext("State")}</.filter_label>
            <.input
              id="search_state"
              name="search[state]"
              type="select"
              options={[{gettext("Open"), "open"}, {gettext("Done & skipped"), "closed"}]}
              value={@search["state"]}
            />
          </div>
          <.button class="h-9 w-10">🔍</.button>
          <:actions>
            <.link
              :if={@rights.create}
              navigate={~p"/companies/#{@current_company.id}/tasks/new"}
              class="blue button"
              id="new_task"
            >
              + {gettext("New Task")}
            </.link>
          </:actions>
        </.list_bar>
      </.form>

      <.list_table>
        <:head>
          <div :if={@search["state"] == "closed"} class="w-44 shrink-0">{gettext("Closed")}</div>
          <div :if={@search["state"] != "closed"} class="w-24 shrink-0">{gettext("Due")}</div>
          <div class="w-[28%] shrink-0">{gettext("Task")}</div>
          <div class="w-28 shrink-0">{gettext("Repeats")}</div>
          <div class="w-40 shrink-0">{gettext("Assignee")}</div>
          <div class="flex-1 min-w-0">{gettext("Latest note")}</div>
          <div class="w-10 shrink-0 text-right">📝</div>
          <div class="w-32 shrink-0"></div>
        </:head>
        <div id="tasks_list" phx-update="stream">
          <div id="tasks-empty" class="hidden only:block p-4 text-sm text-slate-500">
            {gettext("Nothing here.")}
          </div>
          <%= for {dom_id, item} <- @streams.rows do %>
            <%= if item[:heading] do %>
              <.group_heading id={dom_id} group={item.heading} />
            <% else %>
              <div id={dom_id} class={row_class()}>
                <div class={line_class()}>
                  <.closed_cell
                    :if={item.group == :closed}
                    task={item.task}
                    company={@current_company}
                  />
                  <.due_cell
                    :if={item.group != :closed}
                    task={item.task}
                    group={item.group}
                    today={@today}
                  />
                  <.link
                    navigate={~p"/companies/#{@current_company.id}/tasks/#{item.task.id}"}
                    class="w-[28%] shrink-0 truncate font-medium hover:underline"
                    title={item.task.title}
                  >
                    {item.task.title}
                  </.link>
                  <div class={["w-28 shrink-0 truncate text-xs", muted_class()]}>
                    <span :if={repeat_label(item.task)}>↻ {repeat_label(item.task)}</span>
                  </div>
                  <div
                    class="w-40 shrink-0 truncate"
                    title={item.task.assignee && item.task.assignee.email}
                  >
                    {(item.task.assignee && item.task.assignee.email) || "—"}
                  </div>
                  <div
                    class={["flex-1 min-w-0 truncate text-xs", muted_class()]}
                    title={
                      item.latest_note &&
                        FullCircleWeb.Helpers.format_datetime(
                          item.latest_note.inserted_at,
                          @current_company
                        )
                    }
                  >
                    {item.latest_note && item.latest_note.body}
                  </div>
                  <div class={["w-10 shrink-0 text-right tabular-nums text-xs", muted_class()]}>
                    {if item.note_count > 0, do: item.note_count}
                  </div>
                  <div class="w-32 shrink-0 flex justify-end gap-1 opacity-0 group-hover:opacity-100 focus-within:opacity-100">
                    <%= if item.task.status == "open" and Tasks.may_close?(item.task, @current_user, @rights) do %>
                      <button
                        type="button"
                        phx-click="open_close"
                        phx-value-id={item.task.id}
                        phx-value-kind="done"
                        class={["rounded-full px-2 py-0.5 text-xs font-medium", chip_class(:ok)]}
                      >
                        ✓ {gettext("Done")}
                      </button>
                      <button
                        type="button"
                        phx-click="open_close"
                        phx-value-id={item.task.id}
                        phx-value-kind="skip"
                        class={["rounded-full px-2 py-0.5 text-xs font-medium", chip_class(:muted)]}
                      >
                        {gettext("Skip")}
                      </button>
                    <% end %>
                  </div>
                </div>
              </div>
            <% end %>
          <% end %>
        </div>
      </.list_table>
      <.infinite_scroll_footer ended={@end_of_timeline?} />
      <.close_dialog :if={@closing} closing={@closing} />
    </div>
    """
  end
end
