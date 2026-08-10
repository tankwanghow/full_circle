# Egg stock planned sales — selected-row loading list

Date: 2026-08-10
Status: approved

## Problem

On the egg stock day board (`Stock` tab) and the `Weekly Sales` book, the user
plans sales lines per contact. Before loading a lorry, they need a paper list of
*some* of those lines — one route's worth, not the whole board. Today the only
print is the full day report (`/EggStock/:date/print`), which prints everything
and is laid out as a stock report, not as a loading list.

## Goal

Select a subset of planned sales rows on either surface and print just those rows
as a lorry loading list.

Out of scope: planned purchases, the estimated tab, changing the existing day
report.

## Surfaces

Both target surfaces live in `lib/full_circle_web/live/egg_stock_live/form.ex`
and already share a row shape — `w-12` arrow gutter, `w-56` contact, `w-20` per
grade, `w-20` total:

| Surface | Rendered by | Row source | Row id |
|---|---|---|---|
| `Stock` tab → Planned Sales | `detail_lines/1` | `EggStockDayDetail` via `inputs_for` | `dtl[:id].value` |
| `Weekly Sales` tab | `weekly_tab/1` | `DowTemplateLine` via `@dow_params` | `line["id"]` |

## Selection UI

Identical treatment on both surfaces.

- **Checkbox in the left gutter, before the up/down arrows.** Gutter widens from
  `w-12` to `w-[68px]`. Not on the right: that end of a row carries a variable
  number of doc/lock/trash icons, so a checkbox there shifts position row to row
  and cannot be scanned as a column.
- **No selection mode toggle.** Checkboxes are always visible. The action bar
  appears only once at least one row is selected.
- **Section-scoped "select all"** checkbox in the column header row. On the
  `Stock` tab it selects planned *sales* rows only — never the planned purchase
  section.
- **Separators are not selectable** (no checkbox rendered). Their labels still
  reach the printout as group headings; see below.
- **Rows without an id yet** — freshly added lines, and the in-memory orphan doc
  rows produced by `ensure_planned_lines_for_actuals/3` — render a disabled
  checkbox with a "save first" tooltip. Autosave makes this window short.
- **Action bar** renders directly under the section when the selection is
  non-empty: `N rows selected`, total egg count across selected rows,
  `Print selected`, `Clear`.
- `Print selected` is a plain `<a target="_blank">` whose href is rebuilt from the
  current selection on each render. It opens a new tab and never touches the form.
- The weekly book is read-only on today's DOW (`dow_readonly?/1`). Selection and
  printing still work there — read-only applies to editing, not to printing.

### State

- Two separate socket assigns: one for the stock-tab sales selection, one for the
  weekly-sales selection. They never share a set.
- Each holds a `MapSet` of **row ids**, not `dtl.index` / list index — indexes
  shift on move and delete.
- Cleared on date change (`nav_date`, `goto_date`), DOW change (`select_dow`), and
  tab change (`switch_tab`).
- **The checkbox must have no `name` attribute.** It sits inside the
  `phx-change="validate"` form (stock tab) and `phx-change="validate_dow"` form
  (weekly tab); a named input would land in the submitted params and reach the
  changeset. Drive it entirely from the server:
  `phx-click="toggle_print_row"`, `phx-value-id={id}`,
  `checked={MapSet.member?(@selected, id)}`.

## Print view

One LiveView, `FullCircleWeb.EggStockLive.LoadingList`, using the `print_root`
layout. Source-param driven so both surfaces share the template:

```
/companies/:company_id/EggStock/loading_list?src=day&date=2026-08-10&ids=…
/companies/:company_id/EggStock/loading_list?src=dow&kind=sales&dow=3&ids=…
```

`ids` is a comma-separated list of row ids.

### Loading

- `src=day` → load `EggStockDayDetail` by id, scoped to the company and to
  `stock_date == date`, section in `EggStock.planned_sales_sections()`.
- `src=dow` → load `DowTemplateLine` by id, scoped to the company, `kind` and `dow`.
- Ids that do not resolve under that scope are dropped silently — this is also the
  multi-tenant guard.
- Both normalise to the same shape before rendering:
  `%{group_name, contact_name, quantities}`.

### Ordering and grouping

- Rows print in board `position` order, **not** in the order the user clicked
  them. The sheet has to match the physical order of the board or the loader is
  hunting up and down the list.
- Group headings come from separators: walking the full ordered row list, each
  separator's `group_name` becomes a heading, emitted only if at least one
  selected row falls under it. This means the print query must load the section's
  separators too, not only the selected ids.

### Layout

Reuses the `.page` / `.company-name` / `.contact-name` / `.num` CSS idiom already
in `egg_stock_live/print.ex`.

- Header: company name, title `Planned sales — loading list`, date line.
  - `src=day` → the board date.
  - `src=dow` → weekday name plus the upcoming calendar date, via the existing
    `dow_date/2` (same value the DOW buttons show).
- Table columns: `#` · Contact · one column per grade · Total · `✓` (empty box for
  the loader to tick).
- A subtotal row per group — the per-route number the driver checks against.
- A grand total row.
- Footer: `Loaded by` / `Checked by` signature lines.

## Testing

- Context-level: id scoping (ids from another company or another date resolve to
  nothing), ordering by `position`, group headings suppressed when no selected row
  falls under a separator.
- LiveView: toggling a checkbox does not alter the day changeset (the `name`-less
  gotcha), select-all on the sales section leaves the purchase section untouched,
  selection clears on date/DOW/tab change, the print href reflects the current
  selection.

## Notes

The board is light-mode only — `form.ex` and `print.ex` carry no `dark:` variants.
New markup matches that rather than introducing a mixed convention.
