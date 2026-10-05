defmodule FullCircleWeb.ListComponents do
  @moduledoc """
  Building blocks for decluttered listings (one line per record).
  Contract: `.claude/skills/decluttered-index.md`.

  `app.css` remaps many plain colour classes in dark mode (`bg-white`,
  `bg-gray-200`, `text-gray-600`, most borders…) with selectors that beat
  `dark:` variants, so these components use slate shades and opacity variants
  (`bg-sky-50/70`) that are not remapped.
  """
  use Phoenix.Component
  use Gettext, backend: FullCircleWeb.Gettext

  @doc """
  Title, filters and right-aligned actions on one line. Put it *inside* the
  page's search `<.form>` so the filters submit with it.
  """
  attr :title, :string, required: true
  slot :inner_block, doc: "filter inputs (use `filter_label/1` for labels)"
  slot :actions, doc: "Print / New … buttons, right-aligned"

  def list_bar(assigns) do
    ~H"""
    <div class="flex flex-wrap items-end gap-2 mb-3 text-sm">
      <h1 class="text-2xl font-medium mr-3 self-center">{@title}</h1>
      {render_slot(@inner_block)}
      <div class="flex gap-1 ml-auto">{render_slot(@actions)}</div>
    </div>
    """
  end

  slot :inner_block, required: true

  def filter_label(assigns) do
    ~H"""
    <label class="text-xs text-slate-500">{render_slot(@inner_block)}</label>
    """
  end

  @doc """
  Bordered table frame: a header row (`:head`, column divs with the same
  widths as the rows) and the rows (the page's stream container).
  """
  attr :gap, :string,
    default: "gap-2",
    doc: ~s(column gap; "gap-0" for percentage-width columns, which pad their cells instead)

  slot :head, required: true
  slot :inner_block, required: true

  def list_table(assigns) do
    ~H"""
    <div class="rounded border border-slate-300 dark:border-gray-700 overflow-hidden">
      <div class={[
        "flex items-center px-2 py-1.5 bg-slate-200 dark:bg-gray-800 text-xs font-semibold uppercase tracking-wide text-slate-600 dark:text-slate-300",
        @gap
      ]}>
        {render_slot(@head)}
      </div>
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc "Classes for a row's outer div (hover, divider, `group` for hover-only bits)."
  def row_class(extra \\ nil) do
    [
      extra,
      "group border-b border-slate-200 dark:border-gray-700 text-sm",
      "hover:bg-sky-50/70 dark:hover:bg-gray-800/70"
    ]
  end

  @doc "Classes for the single line inside a row (`gap` must match `list_table`)."
  def line_class(gap \\ "gap-2"), do: "flex items-center #{gap} px-2 py-1.5"

  @doc "Muted secondary text (particulars, sub-ids)."
  def muted_class, do: "text-slate-500 dark:text-slate-400"

  def money(nil), do: ""
  def money(amount), do: Number.Currency.number_to_currency(amount)

  @doc "Days past `due_date` while `balance` is still positive; nil otherwise."
  def overdue_days(nil, _balance), do: nil

  def overdue_days(due_date, balance) do
    if balance && Decimal.gt?(balance, 0) do
      days = Date.diff(Date.utc_today(), due_date)
      if days > 0, do: days
    end
  end

  @doc "Right-aligned amount; a muted dash for zero."
  attr :amount, :any, required: true
  attr :class, :any, default: "w-28"

  def amount_cell(assigns) do
    ~H"""
    <div class={["shrink-0 text-right tabular-nums", @class]}>
      <%= if @amount && Decimal.eq?(@amount, 0) do %>
        <span class="text-slate-400">—</span>
      <% else %>
        {money(@amount)}
      <% end %>
    </div>
    """
  end

  @doc "Slim rose overdue-days cell (blank when not overdue); due date in the tooltip."
  attr :days, :any, required: true
  attr :due_date, :any, default: nil

  def overdue_cell(assigns) do
    ~H"""
    <div
      data-col="overdue"
      class="w-16 shrink-0 text-right tabular-nums text-rose-700 dark:text-rose-400"
      title={
        @days && @due_date &&
          gettext("due %{date}", date: FullCircleWeb.Helpers.format_date(@due_date))
      }
    >
      {if @days, do: gettext("%{days}d", days: @days)}
    </div>
    """
  end

  @doc """
  📝 notes count, plus 👷 open tasks when there are any. Both open the index's
  notes modal (notes and tasks panels). With no notes and no tasks the 📝
  button shows on row hover only.
  """
  attr :count, :integer, required: true
  attr :tasks, :integer, default: 0, doc: "open tasks linked to the record"
  attr :id, :string, required: true

  def row_notes_badge(assigns) do
    ~H"""
    <span class={[
      "inline-flex shrink-0 gap-0.5 whitespace-nowrap",
      (@count == 0 and @tasks == 0) && "opacity-0 group-hover:opacity-100"
    ]}>
      <FullCircleWeb.NoteComponents.notes_count_badge count={@count} id={@id} />
      <button
        :if={@tasks > 0}
        type="button"
        phx-click="open_tasks"
        phx-value-id={@id}
        class="rounded bg-amber-500 px-1 text-xs text-white dark:bg-amber-600"
        title={ngettext("1 open task", "%{count} open tasks", @tasks)}
      >
        👷 {@tasks}
      </button>
    </span>
    """
  end

  @doc "Status chip colours: :ok (green), :todo (amber), :bad (rose), :muted."
  def chip_class(:ok),
    do: "bg-emerald-100/80 text-emerald-900 dark:bg-emerald-900/50 dark:text-emerald-300"

  def chip_class(:todo),
    do: "bg-amber-100/80 text-amber-900 dark:bg-amber-900/50 dark:text-amber-300"

  def chip_class(:bad),
    do: "bg-rose-100/80 text-rose-800 dark:bg-rose-900/50 dark:text-rose-300"

  def chip_class(:muted),
    do: "bg-slate-100/80 text-slate-500 dark:bg-gray-800 dark:text-slate-400"

  attr :kind, :atom, default: :muted
  attr :rest, :global
  slot :inner_block, required: true

  def chip(assigns) do
    ~H"""
    <span
      class={["rounded-full px-2 py-0.5 text-xs font-medium whitespace-nowrap", chip_class(@kind)]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </span>
    """
  end
end
