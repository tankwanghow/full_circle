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
      <span class="tabular-nums">{closed_date(@task.closed_at, @company)}</span>
    </div>
    """
  end

  defp closed_date(nil, _company), do: nil

  defp closed_date(at, company),
    do: at |> Timex.to_datetime(company.timezone) |> Helpers.format_date()

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
  attr :group, :atom, required: true

  def group_heading(assigns) do
    ~H"""
    <div
      id={@id}
      class="border-b border-slate-200 bg-slate-50 px-2 py-1 text-xs font-semibold uppercase tracking-wide text-slate-500 dark:border-gray-700 dark:bg-gray-800/60 dark:text-slate-400"
    >
      {group_label(@group)}
    </div>
    """
  end

  attr :closing, :map, required: true, doc: "%{task, kind: :done | :skipped, next_due}"

  @doc "Done / Skip confirmation. Sends confirm_close / cancel_close to the host."
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
          {gettext("This task expects:")} {@closing.task.documents_needed}
        </p>
        <.form for={%{}} as={:close} id="close-form" phx-submit="confirm_close" class="mt-3">
          <textarea
            name="close[note]"
            id="close-note"
            rows="3"
            placeholder={gettext("Closing note (optional) — add files on the task page after")}
            class="w-full rounded border-slate-300 text-sm dark:border-gray-600 dark:bg-gray-800"
          ></textarea>
          <p :if={@closing.next_due} class="mt-1 text-sm text-slate-600 dark:text-slate-400">
            {gettext("Next cycle due")} {Helpers.format_date(@closing.next_due)}
          </p>
          <div class="mt-3 flex justify-end gap-2">
            <button type="button" phx-click="cancel_close" class="gray button">
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
