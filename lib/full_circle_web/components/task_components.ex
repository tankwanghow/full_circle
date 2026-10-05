defmodule FullCircleWeb.TaskComponents do
  @moduledoc "Pieces shared by the Tasks list and the task page."
  use Phoenix.Component
  use Gettext, backend: FullCircleWeb.Gettext

  alias FullCircleWeb.{Helpers, ListComponents}

  attr :task, :map, required: true
  attr :group, :atom, required: true
  attr :today, :any, required: true

  @doc "Due cell: rose \"12d late\", amber \"today\" / \"in 5d\", else the date; — for someday."
  def due_cell(assigns) do
    ~H"""
    <div
      class={[
        "w-24 shrink-0 tabular-nums whitespace-nowrap",
        @group == :overdue && "font-semibold text-rose-700 dark:text-rose-400",
        @group == :due_soon && "font-semibold text-amber-700 dark:text-amber-400"
      ]}
      title={@task.due_date && Helpers.format_date(@task.due_date)}
    >
      {due_text(@task, @group, @today)}
    </div>
    """
  end

  defp due_text(%{due_date: nil}, _group, _today), do: "—"

  defp due_text(%{due_date: d}, :overdue, today),
    do: gettext("%{n}d late", n: Date.diff(today, d))

  defp due_text(%{due_date: d}, :due_soon, today) do
    case Date.diff(d, today) do
      0 -> gettext("today")
      n -> gettext("in %{n}d", n: n)
    end
  end

  defp due_text(%{due_date: d}, _group, _today), do: Helpers.format_date(d)

  attr :task, :map, required: true
  attr :group, :atom, required: true
  attr :today, :any, required: true
  attr :company, :map, default: nil

  @doc """
  Due tile for the task column. Overdue is rose ("3d" / "late"), today is amber,
  a later date is the day and month, someday is "—", and a closed task says
  Done or Skipped. Every dated open tile adds the due year, small, underneath. The full phrase stays in the markup so "3d late" still matches.
  """
  def due_tile(assigns) do
    assigns =
      assign(assigns,
        label: tile_label(assigns.task, assigns.group, assigns.today),
        lines: tile_lines(assigns.task, assigns.group, assigns.today),
        title: tile_title(assigns.task, assigns.company),
        # The due date's year, small, under any dated open tile.
        year: assigns.group != :closed && assigns.task.due_date && assigns.task.due_date.year
      )

    ~H"""
    <div
      class={[
        "flex h-11 w-11 shrink-0 flex-col items-center justify-center rounded-lg px-0.5 text-center leading-none",
        tile_class(@group, @task)
      ]}
      title={@title}
    >
      <%= if @lines do %>
        <span class="text-sm font-bold">{elem(@lines, 0)}</span>
        <span :if={elem(@lines, 1)} class="mt-0.5 text-[10px] font-semibold uppercase">
          {elem(@lines, 1)}
        </span>
      <% else %>
        <span class="text-[11px] font-semibold leading-tight">{@label}</span>
      <% end %>
      <span :if={@year} class="due-tile-year mt-0.5 text-[9px] opacity-75">{@year}</span>
      <span class="sr-only">{@label}</span>
    </div>
    """
  end

  defp tile_label(task, :closed, _today) do
    if task.status == "done", do: gettext("Done"), else: gettext("Skipped")
  end

  defp tile_label(task, group, today), do: due_text(task, group, today)

  defp tile_lines(task, :overdue, today) do
    case String.split(due_text(task, :overdue, today), " ", parts: 2) do
      [top, bottom] -> {top, bottom}
      _ -> nil
    end
  end

  defp tile_lines(%{due_date: d}, :upcoming, _today) when not is_nil(d) do
    {Integer.to_string(d.day), Calendar.strftime(d, "%b")}
  end

  defp tile_lines(%{due_date: d}, :due_soon, today) when not is_nil(d) and d == today do
    {gettext("today"), nil}
  end

  defp tile_lines(_task, _group, _today), do: nil

  defp tile_class(:overdue, _task),
    do: "bg-rose-100 text-rose-800 dark:bg-rose-950 dark:text-rose-200"

  defp tile_class(:due_soon, _task),
    do: "bg-amber-100 text-amber-900 dark:bg-amber-900 dark:text-amber-100"

  defp tile_class(:closed, %{status: "done"}),
    do: "bg-emerald-100 text-emerald-800 dark:bg-emerald-950 dark:text-emerald-200"

  defp tile_class(:someday, _task),
    do: "bg-gray-100 text-gray-400 dark:bg-gray-800 dark:text-gray-500"

  defp tile_class(_group, _task),
    do: "bg-gray-100 text-gray-700 dark:bg-gray-800 dark:text-gray-200"

  defp tile_title(%{due_date: d}, _company) when not is_nil(d), do: Helpers.format_date(d)

  defp tile_title(%{closed_at: at}, company) when not is_nil(at),
    do: Helpers.format_datetime(at, company)

  defp tile_title(_task, _company), do: nil

  @doc "Closed date in the company timezone (`dd-mm-yyyy`), or nil."
  def closed_on(%{closed_at: nil}, _company), do: nil

  def closed_on(%{closed_at: at}, company),
    do: at |> Timex.to_datetime(company.timezone) |> Helpers.format_date()

  attr :task, :map, required: true
  attr :company, :map, required: true

  @doc "Done & skipped list: a Done / Skipped chip and the closed date (company timezone)."
  def closed_cell(assigns) do
    ~H"""
    <div
      class="flex w-44 shrink-0 items-center gap-2 whitespace-nowrap"
      title={Helpers.format_datetime(@task.closed_at, @company)}
    >
      <span class={[
        "rounded-full px-2 py-0.5 text-xs font-medium",
        ListComponents.chip_class(if @task.status == "done", do: :ok, else: :muted)
      ]}>
        {if @task.status == "done", do: gettext("Done"), else: gettext("Skipped")}
      </span>
      <span class="tabular-nums">{closed_on(@task, @company)}</span>
    </div>
    """
  end

  @doc """
  The line above a task's title, the same on the list and the task page:
  "creator · assigned to X", "creator · unassigned", or once closed
  "creator · Done by X".
  """
  def people_line(task) do
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

  @doc "\"Repeat every 2 months · reminder 14 days · Everyone\" — below the title."
  def rhythm(task) do
    [
      "#{gettext("Repeat")} #{repeat_label(task) || gettext("never")}",
      task.reminder_before_days && gettext("reminder %{n} days", n: task.reminder_before_days),
      visibility_label(task.visibility)
    ]
    |> Enum.reject(&(&1 in [nil, false]))
    |> Enum.join(" · ")
  end

  defp visibility_label(nil), do: gettext("Everyone")
  defp visibility_label(["admin"]), do: gettext("Private")
  defp visibility_label(roles) when is_list(roles), do: Enum.join(roles, ", ")

  defp email_name(%{email: email}) when is_binary(email), do: email |> String.split("@") |> hd()
  defp email_name(_), do: nil

  @doc "\"yearly\", \"every 3 months\"… or nil for a one-off."
  def repeat_label(%{recur_unit: nil}), do: nil
  def repeat_label(%{recur_unit: "day", recur_every: 1}), do: gettext("daily")
  def repeat_label(%{recur_unit: "week", recur_every: 1}), do: gettext("weekly")
  def repeat_label(%{recur_unit: "month", recur_every: 1}), do: gettext("monthly")
  def repeat_label(%{recur_unit: "year", recur_every: 1}), do: gettext("yearly")
  def repeat_label(%{recur_unit: "day", recur_every: n}), do: gettext("every %{n} days", n: n)
  def repeat_label(%{recur_unit: "week", recur_every: n}), do: gettext("every %{n} weeks", n: n)
  def repeat_label(%{recur_unit: "month", recur_every: n}), do: gettext("every %{n} months", n: n)
  def repeat_label(%{recur_unit: "year", recur_every: n}), do: gettext("every %{n} years", n: n)

  def group_label(:overdue), do: gettext("Overdue")
  def group_label(:due_soon), do: gettext("Due soon")
  def group_label(:upcoming), do: gettext("Upcoming")
  def group_label(:someday), do: gettext("Someday")
  def group_label(:closed), do: gettext("Done & skipped")

  attr :id, :string, required: true
  attr :item, :map, required: true, doc: "a `Tasks.rows/4` row"
  attr :today, :any, required: true
  attr :company, :map, required: true
  attr :new_tab, :boolean, default: false, doc: "open the task in a new tab (record panels)"
  slot :actions, doc: "right end of the counts row (the list's Done / Skip)"

  @doc """
  One task as the Tasks list draws it, in the task page's order: due tile,
  people, title, description, rhythm (one link to the task), the latest
  progress note as a quote, then 📝 / 🔗. A record's tasks panel uses it too.
  """
  def task_row(assigns) do
    assigns =
      assign(assigns, path: "/companies/#{assigns.company.id}/tasks/#{assigns.item.task.id}")

    ~H"""
    <%!-- data-post-open: a click on empty space opens the task (post_open.js). --%>
    <article
      id={@id}
      data-post-open
      class="flex cursor-pointer gap-3 border-b border-gray-200 px-4 py-3 hover:bg-gray-50 dark:border-gray-700 dark:hover:bg-gray-700/60"
    >
      <.due_tile task={@item.task} group={@item.group} today={@today} company={@company} />
      <div class="min-w-0 flex-1">
        <%!-- People, title, description and rhythm are one link to the task. --%>
        <.link :if={!@new_tab} navigate={@path} data-post-link class="block">
          <.task_row_text item={@item} company={@company} />
        </.link>
        <a :if={@new_tab} href={@path} target="_blank" data-post-link class="block">
          <.task_row_text item={@item} company={@company} />
        </a>
        <%!-- A quoted note, so it never reads as the task's description. --%>
        <p
          :if={@item.latest_note}
          class="mt-1 truncate rounded-r border-l-2 border-sky-400 bg-sky-50 py-0.5 pl-2 pr-1 text-xs italic text-sky-900 dark:border-sky-500 dark:bg-sky-950/40 dark:text-sky-100"
        >
          {@item.latest_note.body}
        </p>
        <div class="mt-1 flex items-center gap-3 text-xs text-gray-500 dark:text-gray-400">
          <span title={gettext("Progress")}>📝 {@item.note_count}</span>
          <span>🔗 {@item.link_count}</span>
          <span :if={@actions != []} class="ml-auto flex gap-1">{render_slot(@actions)}</span>
        </div>
      </div>
    </article>
    """
  end

  attr :item, :map, required: true
  attr :company, :map, required: true

  defp task_row_text(assigns) do
    ~H"""
    <div class="text-sm text-gray-500 dark:text-gray-400">{row_people(@item, @company)}</div>
    <span class="font-bold">{@item.task.title}</span>
    <span
      :if={@item.task.descriptions not in [nil, ""]}
      class="block truncate text-[0.9375rem] text-gray-800 dark:text-gray-200"
    >
      {@item.task.descriptions}
    </span>
    <div class="text-sm text-gray-500 dark:text-gray-400">{rhythm(@item.task)}</div>
    """
  end

  # The people line; a closed row adds when it was closed.
  defp row_people(%{group: :closed, task: task}, company) do
    [people_line(task), closed_on(task, company)] |> Enum.reject(&is_nil/1) |> Enum.join(" · ")
  end

  defp row_people(%{task: task}, _company), do: people_line(task)

  attr :id, :string, required: true
  attr :group, :atom, required: true

  def group_heading(assigns) do
    ~H"""
    <div
      id={@id}
      class={[
        "px-4 pb-1 pt-4 text-xs font-bold uppercase tracking-wide",
        @group == :overdue && "text-rose-600 dark:text-rose-400",
        @group == :due_soon && "text-amber-600 dark:text-amber-400",
        @group not in [:overdue, :due_soon] && "text-gray-500 dark:text-gray-400"
      ]}
    >
      {group_label(@group)}
    </div>
    """
  end

  attr :task_id, :string, required: true
  attr :target, :any, default: nil

  @doc "✓ Done and Skip on a list row: open_close to the host (or `target`)."
  def close_buttons(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="open_close"
      phx-value-id={@task_id}
      phx-value-kind="done"
      phx-target={@target}
      class="rounded-full bg-emerald-600 px-2.5 py-0.5 text-xs font-semibold text-white hover:bg-emerald-500"
    >
      ✓ {gettext("Done")}
    </button>
    <button
      type="button"
      phx-click="open_close"
      phx-value-id={@task_id}
      phx-value-kind="skip"
      phx-target={@target}
      class="rounded-full bg-gray-200 px-2.5 py-0.5 text-xs font-semibold text-gray-700 hover:bg-gray-300 dark:bg-gray-700 dark:text-gray-200"
    >
      {gettext("Skip")}
    </button>
    """
  end

  attr :closing, :map, required: true, doc: "%{task, kind: :done | :skipped, next_due}"
  attr :target, :any, default: nil

  @doc "Done / Skip confirmation. Sends confirm_close / cancel_close to the host (or `target`)."
  def close_dialog(assigns) do
    ~H"""
    <div id="close-dialog" class="fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-4">
      <div class="w-full max-w-md rounded-lg border border-slate-300 bg-white p-4 shadow-xl dark:border-gray-700 dark:bg-gray-900">
        <p class="text-lg font-semibold">
          {if @closing.kind == :done, do: gettext("Mark done"), else: gettext("Skip this time")} — {@closing.task.title}
        </p>
        <p
          :if={@closing.kind == :done and @closing.task.documents_needed}
          class="mt-2 rounded border border-amber-300/70 bg-amber-100/80 px-2 py-1 text-sm text-amber-900 dark:border-amber-700/60 dark:bg-amber-900/40 dark:text-amber-200"
        >
          {gettext("Task expects:")} {@closing.task.documents_needed}
        </p>
        <.form
          for={%{}}
          as={:close}
          id="close-form"
          phx-submit="confirm_close"
          phx-target={@target}
          class="mt-3"
        >
          <textarea
            name="close[note]"
            id="close-note"
            rows="3"
            placeholder={gettext("Progress (optional) — add files on the task page after")}
            class="w-full rounded border-slate-300 text-sm dark:border-gray-600 dark:bg-gray-800"
          ></textarea>
          <p :if={@closing.next_due} class="mt-1 text-sm text-slate-600 dark:text-slate-400">
            {gettext("Next cycle due")} {Helpers.format_date(@closing.next_due)}
          </p>
          <div class="mt-3 flex justify-end gap-2">
            <button type="button" phx-click="cancel_close" phx-target={@target} class="gray button">
              {gettext("Cancel")}
            </button>
            <button
              type="submit"
              class={if @closing.kind == :done, do: "green button", else: "orange button"}
            >
              {if @closing.kind == :done, do: gettext("Done"), else: gettext("Skip")}
            </button>
          </div>
        </.form>
      </div>
    </div>
    """
  end
end
