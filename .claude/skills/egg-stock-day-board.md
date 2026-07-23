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

## UI conventions (form)

- Single planned board surface; delete control sits **after** document actions on planned lines.
- Separators + drag/reorder via `position` / group fields.
- Today print layout under `egg_stock_live/print.ex`.

## Gotchas

1. **Ad-hoc lines need `contact_name`** when `contact_id` is nil — empty labels confuse attach/sync.
2. **Separators must not carry qty or contact** — changesets clear them.
3. **Qty maps are string-keyed grade names** — normalize with `normalize_qty_map/1` / `to_int/1`.
4. **cast_assoc can miss map-only qty updates** — use `persist_synced_detail_quantities/3` after sync.
5. **Legacy section names** — never hardcode only `planned_order`; include legacy in filters.
6. **Local restore vs trading schema** — use `scripts/restore_backup.sh` (drop/recreate DB) rather than `pg_restore -c` when local has tables newer than the dump.

## Key files

```
lib/full_circle/egg_stock.ex
lib/full_circle/egg_stock/{egg_grade,egg_stock_day,egg_stock_day_detail,dow_template_line}.ex
lib/full_circle_web/live/egg_stock_live/{form,print,production_report}.ex
scripts/restore_backup.sh
test/full_circle/egg_stock_test.exs
```
