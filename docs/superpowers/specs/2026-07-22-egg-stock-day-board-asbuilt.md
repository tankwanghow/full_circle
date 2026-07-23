# Egg Stock Day Board — As-Built

**Date:** 2026-07-22  
**Status:** Implemented  
**App:** FullCircle (`full_circle`)  
**Skill:** `.claude/skills/egg-stock-day-board.md`  
**Context:** `FullCircle.EggStock`

## Summary

Daily egg stock board for poultry operations: grade columns, planned sales/purchase
lines (including ad-hoc contacts), weekly day-of-week template books, document
overlay from invoices/receipts/payments, hybrid 7-day forecast, and print/production
report LiveViews.

## Entities

| Schema | Table | Notes |
|--------|-------|-------|
| `EggGrade` | egg grades | Column set per company |
| `EggStockDay` | one per company × date | `closing_bal` / opening / expired as JSON maps |
| `EggStockDayDetail` | planned lines | sections, separators, ad-hoc `contact_name` |
| `DowTemplateLine` | weekly books | `kind` sales\|purchase, `dow` 1–7 |

## Planned sections

- Canonical: `"planned_order"`, `"planned_purchase"`
- Legacy read aliases: `"actual_order"`, `"actual_purchase"`

## Behaviour highlights

1. **Single planned surface** — planned lines + orphan document rows; reorder + separators.
2. **Ad-hoc contacts** — `contact_id` nil + persisted `contact_name`; attach real contact after document create via `attach_contact_from_document/3`.
3. **DOW books** — template per weekday; `copy_dow_book_to_day/4` / `clear_day_planned_section/4` (edited in app UI after initial load).
4. **Hybrid forecast** — avg production from days with real closing + planned sales/purchases; actual closing wins when present.

## Routes

- `/companies/:id/egg_stock` (today), `/egg_stock/:date`, production report, print

## Auth

`:create_egg_stock_day`, `:update_egg_stock_day`, `:delete_egg_stock_day`

## Key files

See skill `.claude/skills/egg-stock-day-board.md`.
