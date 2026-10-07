---
name: receipt-capture
description: Use when working on photo/PDF receipt capture on New Payment or New Purchase Invoice — Receipts.Extract (AI prompt, JSON contract, checks), Receipts.Prefill (field mapping, funds account, SST/rounding lines, warnings), FullCircleWeb.ReceiptCapture (tray, blank-only merge, receipt note on save), or the "llm_receipt" AI settings.
---

# Receipt capture (PurInvoice / Payment from a photo)

Spec: `docs/superpowers/specs/2026-10-07-receipt-capture-design.md`.
For bills that have an LHDN e-invoice, use `e-invoice-bill-prefill.md` instead.
OCR only serves the paper-only tail.

## Pipeline
`Receipts.Extract.run/4` (file → `%Extracted{}`) → `Receipts.Prefill.build/4`
(→ attrs + warnings) → `ReceiptCapture.merge_params/3` (blank-only) → the form's `validate/2`.
Extract and Prefill know nothing about LiveView. A future inbox calls them as they are.

## Contracts that bite
- **Settings:** use `Sys.llm_settings(company, :receipt)`. Never read `"llm"` directly.
  Blank `"llm_receipt"` fields fall back to `"llm"`.
- **Supplier bill no → `e_inv_internal_id`.** `pur_invoice_no` is our gapless PINV
  number and is never seeded. Payment puts "<shop> #<doc_no>" in `descriptions`.
- **Not recognised** (`recognized: false`, or no total and no lines): only
  `descriptions` = summary (≤ 200 chars) is seeded, plus a warning.
- **The model is never trusted:** every value is parsed in `Extract.parse/2`. A
  value that doesn't parse becomes nil + a warning. Lines that don't add up warn.
  Tax-inclusive or tax-exclusive line amounts both pass.
- **Seeded-line traps** live in `DocPrefill.seed_lines/1` (`unit_multiplier` 0;
  qty into `quantity`, then `package_qty` once a good is applied; percent → fraction).
- **Extra lines:** SST given only as a total, and a non-zero rounding, each become
  their own line with the good blank.
- **Funds account:** the sole account → "Cash In Hand" (exact name) for a cash
  receipt → blank.
- **Merge fills only blanks.** Zero counts as blank. The contact
  (`contact_name/id/tax_id/reg_no`) and funds-account fields move as **groups**.
  Lines are replaced only when no line has a good, qty or price.
- **One read per tray:** the first file triggers it (state `:idle` → `:reading`).
  Later files only attach. ↻ Read again re-reads on purpose.
- **Save:** `attach_multi/5` appends `Notes.create_note` (title "🧾 Receipt",
  Everyone, subject = the new doc) to the create Multi. The doc and its note
  commit together. A failed save leaves the tray for a re-save. With no
  `:create_note` permission the step is skipped and a `:warn` flash says so.
- **Limits:** images over 5 MB are refused before the call; 90 s timeout;
  `max_tokens` 4096.
- **Tests:** stub `Application.put_env(:full_circle, :llm_http, fn url, headers,
  body, timeout -> …)` with `async: false`. LiveView tests: `Trays.open` +
  `Attachments.attach_to_tray`, then `render(lv)` and `render_async(lv)`.
