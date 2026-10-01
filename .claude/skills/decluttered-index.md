---
name: decluttered-index
description: Use when building or changing a FullCircle listing/index page (index.ex + index_component.ex rows), its top bar, columns, e-invoice status column, infinite scroll, or print selection — and when a listing looks cluttered, mis-aligned, or wrong in dark mode.
---

# Decluttered listings — contract

Every listing is **one line per record** in a shared frame. Pilot: Invoice
Listing; rolled out to all document and master-data listings (2026-10-01).
The E-Invoices listing (`e_inv_list_live`) uses the same frame with one
`IndexComponent` for both directions (LHDN doc left, Full Circle doc or
"+ New …" links in the last column). Not converted (special-purpose): Notes
feed, Punch Ingest Log, Punch (time attendance) index.

## Building blocks (`FullCircleWeb.ListComponents`)

- `<.list_bar title=…>` — title · filters (inner block) · `<:actions>`
  (Print / Pre Print / **+ New …** last). Put it *inside* the page's search
  `<.form>`; master-data pages instead put `<.search_form compact … />` in it.
- `<.filter_label>` for filter labels.
- `<.list_table gap=…>` with `<:head>` (column divs) wrapping the stream
  container. Rows: `class={row_class(@ex_class)}` + an inner
  `class={line_class()}` (or one div with both).
- `amount_cell` (right, tabular, "—" for zero), `overdue_cell` (rose "27d",
  due date in tooltip), `row_notes_badge` (empty button on hover only),
  `chip kind={:ok | :todo | :bad | :muted}`, `money/1`, `muted_class/0`.

## Column rules

- Text left, numbers right (`text-right tabular-nums`). Never centre.
- Cells are `shrink-0 truncate` with full text in `title`; secondary data
  (TIN/RegNo, contact info, fixed-asset accounts) goes in tooltips, not lines.
- Header and row cells use **identical widths**.
- **Percentage widths summing to 100%** → `list_table gap="gap-0"`,
  `line_class("gap-0")` and `px-1` on cells; otherwise `gap-2` pushes the
  last column off the edge.
- A `truncate` element that is a **flex child needs `min-w-0`**, and the
  notes badge must stay `shrink-0 whitespace-nowrap` — otherwise long names
  wrap and rows grow to two lines.

## e-Invoice column (`FullCircleWeb.EInvComponents`)

`einv_state(e_inv_uuid, e_invs)` → `:valid | {:problem, label} |
{:match_one, einv} | {:match_many, n} | :none`. `einv_chip` renders it
(single candidate = inline **Match**; `:none` = "Not sent" / "Not received"
link to MyInvois, copying the doc no); `einv_toggle` + `einv_details` show
every candidate with Match / Remove Match / New E-Invoice. The row component
keeps its `"match"`/`"unmatch"` handlers, adds `"toggle_einv"`, and must
default `@einv_open` in **`update/2`** (`assign_new` inside `render` never
reaches the socket → KeyError on toggle). Receipts/Payments with
`got_details == 0` show an "n/a" chip and no toggle.

## Dark mode trap

`assets/css/app.css` remaps many plain classes in dark mode
(`bg-white`, `bg-gray-200`, `bg-*-200`, `text-gray-600`, `text-*-800`, most
borders…) with `.dark .x` selectors that **beat `dark:` variants**. Use slate
shades and opacity-suffixed classes (`bg-amber-100/80`, `bg-sky-50/70`) plus
explicit `dark:` styles; check both themes.

## Behaviour contracts

- **Infinite scroll:** `<.infinite_scroll_footer ended=…>` carries the
  `InfiniteScroll` hook and sends `"next-page"` whenever it is on screen
  (also on first render). Do **not** add `phx-viewport-bottom`. The page must
  handle `"next-page"` and set `@end_of_timeline?`.
- **Print selection:** checkboxes use the two-input pattern (checked /
  unchecked `<input>` with the same id) so a server toggle re-renders;
  `Helpers.can_print?/3` hides Print at 0 selected and above the max.
- **Due dates:** invoice / purchase-invoice index queries take
  `coalesce(inv.due_date, txn.doc_date)` (old imported rows have no doc);
  payables are negative, so overdue uses `Decimal.abs(balance)`.

## Tests

`test/full_circle_web/live/invoice_index_live_test.exs` (behaviour),
`decluttered_einv_listings_test.exs` (5 e-invoice listings),
`e_inv_list_live_test.exs` (E-Invoices listing, match / remove match),
`decluttered_listings_test.exs` (smoke for the rest).
