---
name: egg-stock-day-board
description: Use when working on FullCircle egg stock day board, weekly DOW books, planned sales/purchase lines, ad-hoc contacts, separators, hybrid forecast, or egg_stock LiveViews/print.
---

# Egg Stock Day Board

Domain knowledge for `lib/full_circle/egg_stock.ex`, `lib/full_circle/egg_stock/*`,
and UI under `lib/full_circle_web/live/egg_stock_live/`.

## Mental model

| Piece | Role |
|-------|------|
| **EggGrade** | Company grade columns (name + position). Qty maps are grade-name keyed. |
| **EggStockDay** | One row per company × `stock_date` (opening/closing/expired JSON maps). |
| **EggStockDayDetail** | Planned lines on a day (sales or purchase section). |
| **DowTemplateLine** | Weekly book template: kind sales/purchase × DOW 1–7 (Monday=1). |

Routes:

- `/egg_stock` — today
- `/egg_stock/:date` — any day form
- `/egg_stock/production_report`
- print: `/EggStock/:date/print`

Auth: `:create_egg_stock_day`, `:update_egg_stock_day`, `:delete_egg_stock_day`.

## Planned sections (string values)

Canonical:

- sales → `"planned_order"`
- purchase → `"planned_purchase"`

Legacy still accepted for reads: `"actual_order"`, `"actual_purchase"`.  
Always filter with `planned_sales_sections()` / `planned_purchase_sections()`.

## Day detail lines

Fields that matter:

- `contact_id` — optional; **nil = ad-hoc name** using persisted `contact_name`
- `contact_name` — always stored (label + ad-hoc fallback)
- `is_separator` — visual group break; clears contact + quantities
- `group_name` / `group_position` / `position` — board ordering
- `quantities` — map of grade name → count
- `ignore` — exclude from totals when set

**Planned board is a single surface:** planned lines + orphan document rows
(actual Invoice/PurInvoice/Receipt/Payment activity with no matching planned
contact) appear together. Orphans are created in-memory via
`ensure_planned_lines_for_actuals/3`.

### Sync from actual documents

1. `actual_sales_for_date` / `actual_purchases_for_date` aggregate issued docs by contact.
2. `overlay_actual_quantities/2` replaces planned qty when same `contact_id` has docs.
3. `sync_day_details_from_actuals/3` can bind ad-hoc lines to a contact by name match.
4. `persist_synced_detail_quantities/3` writes map qty changes with **direct updates**
   (not only cast_assoc — map diffs are easy to miss).

### Ad-hoc → real contact after invoicing

When a document is created from a planned ad-hoc line, call
`attach_contact_from_document/3` (prefers `detail_id`; falls back to
load_date + side + original name). Wired from invoice/pur_invoice/receipt/payment forms.

## Weekly DOW books

`DowTemplateLine`: `kind` in `sales|purchase`, `dow` in `1..7`.

- `list_dow_lines/3`, `save_dow_lines/5`
- `copy_dow_book_to_day/4` — replaces that day's planned section with the book for that weekday
- `clear_day_planned_section/4` — clears planned sales or purchases on a day

Weekly books are edited in the app UI (one-time ODS import tooling was removed after prod load).

## Hybrid forecast

- **Opening**: walk from latest day with real closing; fill gaps with
  `avg_production + planned purchases − planned sales`
  (`compute_estimated_opening/3`).
- **Avg production** from days that have non-empty closing_bal
  (`compute_avg_production/2`).
- **7-day forecast** `compute_7day_forecast/3` uses planned totals + avg prod;
  if a day already has actual closing, that closing wins.
- Production identity per day: `sold + expired + closing − opening − bought`.

## Estimated tab navigation

Rows in the Estimated tab are clickable (`forecast_table` assigns `row_click`,
`row_kind`, `highlight_date`, `highlight_class`):

- **Closing** rows → `goto_date` (opens the Stock tab for that day)
- **Est. Sales / Purchases** rows → `goto_weekly` (opens `weekly_sales` /
  `weekly_purchases` for that row's DOW) — **except today's row**, which falls
  back to `goto_date`
- Highlighted row is the board date **+1** (board 25th → 26th highlighted),
  blue for sales, emerald for purchases

`goto_date` now calls `flush_autosave/1` even when the date is unchanged, and
re-loads the "now" tab instead of returning early.

## UI conventions (form)

- Single planned board surface; delete control sits **after** document actions on planned lines.
- Separators + drag/reorder via `position` / group fields.
- Today print layout under `egg_stock_live/print.ex`.

## Loading list (selected planned rows)

Tick rows on the Stock tab (planned **sales** only) or on either weekly book
(**sales or purchase**) and print just those rows as a lorry loading list.

- `EggStock.loading_list_groups(company_id, source, selected_ids)` —
  `source` is `{:day, %Date{}}` for the day board or `{:dow, kind, dow}` for
  the weekly book (e.g. `{:dow, "sales", 2}`). Returns
  `[%{group_name: String.t(), rows: [%{id, contact_name, quantities}]}]`, ordered
  by board `position`, grouped by the separator label above each run of rows.
  Groups with no selected row are dropped. Ids that fall outside the scope are
  dropped — that is also the multi-tenant guard.
- Print view: `EggStockLive.LoadingList` at
  `/companies/:company_id/EggStock/loading_list?src=day&date=YYYY-MM-DD&ids=id1,id2`
  or `/companies/:company_id/EggStock/loading_list?src=dow&kind=sales&dow=N&date=YYYY-MM-DD&ids=id1,id2`.
- **The dow URL's `date` is board-anchored, and it is authoritative.** The weekly
  DOW buttons label themselves `dow_date(@date, d)` where `@date` is the *board*
  date, which can be in the past. The href therefore carries
  `date: Date.to_iso8601(dow_date(@date, @dow))` so the sheet prints the same
  date as the button that was clicked. `parse_source/1` prefers that param and
  only falls back to `EggStock.dow_date(Date.utc_today(), dow)` when it is
  absent, which keeps URLs copied before the param existed working.
- **The sheet title follows the source kind**: `{:dow, "purchase", _}` prints
  `"Planned purchases — loading list"`, everything else prints
  `"Planned sales — loading list"`. `src=day` is always sales — the Stock tab
  renders planned purchases with `selectable={false}`.
- Selection state lives in the `:sel_sales_ids` / `:sel_dow_ids` socket assigns
  as `MapSet`s of **row ids** (strings). Never list index, which shifts on
  move/delete. Both assigns are initialised to `MapSet.new()` in `mount/3` and
  are both cleared by `clear_print_selection/1`, which runs on tab switch, date
  navigation, and weekday change.
- **Deleting a row must prune its id from the selection.** `delete_detail` and
  `delete_dow_line` only stage the removal and schedule an autosave — the row
  survives in the DB for up to `autosave_delay` seconds, so without a
  `MapSet.delete/2` a cancelled order would still print on the warehouse sheet.
- **Both boards read live form state, never the DB-loaded copy.** On the Stock
  tab, `selectable_sales_ids/1` and `selected_rows_total/3` go through
  `live_day_details/1`, which pulls the rows out of the `@form` changeset —
  **not** `@day.egg_stock_day_details`, which is only refreshed by
  `do_save_day`. Reading `@day` was a real bug: select-all re-selected a row
  deleted earlier in the session (still present in `@day` until the autosave
  fired) even though it was no longer rendered, and that cancelled order would
  then print. The weekly board is equivalent by construction — `@dow_params`
  is already live. Pinned by "select all does not resurrect a row deleted in
  this session".

### Events (Stock tab — day board)

| Event | What it does |
|-------|--------------|
| `"toggle_print_row"` | Toggle one id in `:sel_sales_ids` |
| `"toggle_all_print_rows"` | Select all selectable; if already all selected, clear |
| `"clear_print_rows"` | Clear `:sel_sales_ids` |

### Events (Weekly tab — both sales and purchase books)

| Event | What it does |
|-------|--------------|
| `"toggle_dow_print_row"` | Toggle one id in `:sel_dow_ids` |
| `"toggle_all_dow_print_rows"` | Select all selectable; if already all selected, clear |
| `"clear_dow_print_rows"` | Clear `:sel_dow_ids` |

### Helper functions (`form.ex`)

- `live_day_details/1` — the day board's rows straight from the `@form`
  changeset. Every selection helper on the Stock tab goes through it; reaching
  for `@day.egg_stock_day_details` instead reintroduces the stale-row bug above.
- `selectable_sales_ids/1` — saved, non-separator planned-sales rows only
  (id not nil/empty; section in `EggStock.planned_sales_sections()`), taken
  from `live_day_details/1`.
- `selectable_dow_ids/1` — saved, non-separator, non-deleted weekly rows.
- `all_selected?/2` — the single "every selectable row is ticked" predicate
  (false when nothing is selectable). Both `all_sales_selected?/2` and
  `all_dow_selected?/2` and both select-all handlers go through it; do not
  re-inline the `MapSet.subset?` check.
  `selectable_sales_ids`/`selectable_dow_ids` and
  `selected_rows_total`/`selected_dow_total` stay separate on purpose — the two
  boards hold genuinely different shapes (changeset-backed `inputs_for` rows vs
  plain string-keyed `@dow_params` maps).
- `loading_list_href/3` — builds the
  `/companies/:company_id/EggStock/loading_list?…` URL with `src`, `date`,
  `dow`, `kind`, and comma-joined `ids` query params.
- `print_action_bar` component — renders a bar below the section when count > 0,
  showing selected count, egg total, a "Print selected" link (target="_blank"),
  and a "Clear" button. Uses `clear_event="clear_print_rows"` for Stock tab and
  `clear_event="clear_dow_print_rows"` for the weekly tab.

### Gotcha: the selection checkbox must not have a `name`

Both boards are inside a `phx-change` form. A named checkbox would be submitted
with the rest of the row and reach the changeset. Drive it from the server only:
`phx-click`, `phx-value-id`, and `checked={MapSet.member?(...)}`. No `name` attr.

Rows with no id yet (freshly added, and the in-memory orphan rows from
`ensure_planned_lines_for_actuals/3`) render a disabled checkbox.

## Gotchas

1. **Ad-hoc lines need `contact_name`** when `contact_id` is nil — empty labels confuse attach/sync.
2. **Separators must not carry qty or contact** — changesets clear them.
3. **Qty maps are string-keyed grade names** — normalize with `normalize_qty_map/1` / `to_int/1`.
4. **cast_assoc can miss map-only qty updates** — use `persist_synced_detail_quantities/3` after sync.
5. **Legacy section names** — never hardcode only `planned_order`; include legacy in filters.
6. **Local restore vs trading schema** — use `scripts/restore_backup.sh` (drop/recreate DB) rather than `pg_restore -c` when local has tables newer than the dump.
7. **Selection checkboxes need no `name`** — see the loading list section above.
8. **No Floki — use LazyHTML for HTML-attribute assertions in tests.** LiveView 1.2
   ships `lazy_html 0.1.12` (in `mix.lock`). HTML-attribute assertions use
   `LazyHTML.from_fragment/1`, `LazyHTML.query/2`, and `LazyHTML.attribute/2`.
   Critical anti-vacuity rule: `LazyHTML.attribute(matches, "name") == []` passes
   trivially when the query matches **zero** elements — always assert the expected
   element count first. The canonical idiom, from
   `test/full_circle_web/live/egg_stock_form_selection_live_test.exs`:

   ```elixir
   boxes =
     html
     |> LazyHTML.from_fragment()
     |> LazyHTML.query(~s{input[type=checkbox][phx-click=toggle_print_row]})

   # anti-vacuity: assert the expected count before checking attributes
   assert Enum.count(boxes) == 3
   assert LazyHTML.attribute(boxes, "name") == []
   ```

   Absence assertions alone under-pin the markup. Also assert what must be
   **present**: the sorted `phx-value-id` values equal the seeded row ids (the
   handler matches `%{"id" => id}`, so a missing `phx-value-id` crashes in the
   browser while every `render_click` test stays green), and query the select-all
   checkbox by its `phx-click` and assert exactly one match.

## Key files

```
lib/full_circle/egg_stock.ex
lib/full_circle/egg_stock/{egg_grade,egg_stock_day,egg_stock_day_detail,dow_template_line}.ex
lib/full_circle_web/live/egg_stock_live/{form,print,loading_list,production_report}.ex
scripts/restore_backup.sh
test/full_circle/egg_stock_test.exs
test/full_circle_web/live/egg_stock_form_selection_live_test.exs
test/full_circle_web/live/egg_stock_loading_list_live_test.exs
```
