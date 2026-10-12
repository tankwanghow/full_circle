---
name: receipt-capture
description: Use when working on photo/PDF receipt capture on New Payment or New Purchase Invoice — Receipts.Extract (AI prompt, {"documents": […]} list contract, kinds, checks), Receipts.Prefill (field mapping, multi-receipt claims, learnt goods per kind, funds account, SST/rounding lines, warnings), FullCircleWeb.ReceiptCapture (tray, blank-only merge, receipt note on save), or the "llm_receipt" AI settings.
---

# Receipt capture (PurInvoice / Payment from a photo)

Spec: `docs/superpowers/specs/2026-10-07-receipt-capture-design.md`.
For bills that have an LHDN e-invoice, use `e-invoice-bill-prefill.md` instead.
OCR only serves the paper-only tail.

## Pipeline
`Receipts.Extract.run/4` (file → `[%Extracted{}]`, never empty) → `Receipts.Prefill.build/4`
(→ attrs + warnings) → `ReceiptCapture.merge_params/3` (blank-only) → the form's `validate/2`.
Extract and Prefill know nothing about LiveView. A future inbox calls them as they are.
Multi-receipt spec: `docs/superpowers/specs/2026-10-11-multi-receipt-capture-design.md`.

## Contracts that bite
- **Settings:** use `Sys.llm_settings(company, :receipt)`. Never read `"llm"` directly.
  Blank `"llm_receipt"` fields fall back to `"llm"` **only when the receipt
  provider is blank or the same as the shared one**; on another provider the
  endpoint, model and key start blank (a Gemini key must never reach Anthropic).
  Only admins can save either block (`can?(:update_company)` checked in the
  save handler — the template hiding it is not enough).
- **Supplier bill no → `e_inv_internal_id`.** `pur_invoice_no` is our gapless PINV
  number and is never seeded. Payment puts "<shop> #<doc_no>" in `descriptions`.
- **Not recognised** (`recognized: false`, or no total and no lines): only
  `descriptions` = summary (≤ 200 chars) is seeded, plus a warning.
- **List contract:** the AI replies `{"documents": [...]}`, one entry per bill or
  receipt (a bill across pages is one entry). `Extract.parse_documents/2` also
  takes the old single-object shape and never returns `[]`.
  `Prefill.build/4` takes the list: only recognised entries count (the rest
  are dropped with a warning). One → the struct clause, unchanged. PurInvoice →
  the first, plus "only the first was used". Payment with 2+ → `build_many/3`.
- **2+ receipts on a Payment (a claim):** no payee keys in the seed at all (the
  claimant isn't a shop; the merge keeps one picked first), `learn`/`duplicate`
  nil. One line per receipt, `"<shop> #<doc_no> <DD/MM/YYYY>"`, qty 1,
  price = total (0 + warning when none), date-sorted (undated last). Amount =
  sum, pay date = latest, Cash In Hand only if all cash. Per-receipt warnings
  are prefixed with `"<shop> #<doc_no>: "`. Cap 40 (in `Prefill`, read order).
- **Kinds and learnt goods:** the AI tags each receipt `kind` (Fuel, Toll,
  Parking, Hotel, Meal, Transport, Other — fixed English, never translated).
  2+ receipt lines read `"<Kind> · <shop> #<no> <date>"`; `learnt_goods/2`
  copies the good (default package), account and tax code of the latest saved
  Payment line starting `"<Kind> · "` with a good. Never for Other. A learnt
  tax code with a rate warns (receipt totals already include tax).
- **Duplicate claims:** `claimed_warning/2` matches an earlier Payment line whose
  text holds `#<doc_no>` as a whole word (bound regex param, escaped) and whose
  `qty × price + discount` is within 0.01 (discount is stored ≤ 0). It depends
  on the line text above. Repeats inside one file warn too.
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
- **Limits:** an image whose **base64** exceeds 5 MB (raw ≳ 3.75 MB) is refused
  before the call — the AI's limit is on the encoded payload; 180 s timeout; `max_tokens` 32_768 (40 receipts with lines) (Gemini 2.5 thinking tokens count against it).
- **Learning identifiers:** `Prefill` returns `learn: {contact_id, tin, brn}`
  only when the contact matched by TIN/BRN (nil on a name match or no match).
  After save, `ReceiptCapture.learn_identifiers/4` stamps them only if the
  saved contact is that same contact — never onto one the clerk picked
  instead. Logged as "learnt from Receipt".
- **Duplicate warning** is `seed.duplicate`, separate from `warnings`. The form
  re-checks it (`recheck_duplicate/3`) after the read merges and on every
  validate, against the form's current contact/date/amount.
- **Receipt-note failure** on save returns `{:error, :receipt_note, …}`; both
  forms have their own clause (flash, keep form and tray) — it must not fall
  into the generic changeset clause.
- **Tests:** stub `Application.put_env(:full_circle, :llm_http, fn url, headers,
  body, timeout -> …)` with `async: false`. LiveView tests: `Trays.open` +
  `Attachments.attach_to_tray`, then `render(lv)` and `render_async(lv)`.
