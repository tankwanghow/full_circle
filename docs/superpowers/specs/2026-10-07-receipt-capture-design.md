# Receipt capture: PurInvoice / Payment from a photo

Date: 2026-10-07 · Status: approved in conversation, awaiting spec review

## Why

Supplier bills that carry an LHDN e-invoice are already prefilled from the synced
e-invoice (`.claude/skills/e-invoice-bill-prefill.md`). In July 2026 we rejected
OCR bill capture because 97% of bills had an e-invoice. We said to reconsider it
only for the paper-only tail. This spec covers that tail:

- **Petty-cash spending receipts.** These come from hardware shops, petrol
  stations and workshops, and have no e-invoice (consolidated). They are paid at
  once, so they become **Payments** with direct-expense lines.
- **A company whose suppliers do not issue e-invoices.** Its bills come on paper
  or as an emailed PDF and become **PurInvoices**.

The clerk takes a photo of the paper (or drops in the PDF). The AI fills in the
form. The clerk corrects it and confirms. Nothing is saved until the clerk saves.

## Decisions (from the brainstorm)

| # | Decision |
|---|---|
| 1 | **Desk-first.** The clerk opens New PurInvoice / New Payment and scans from there. A "captured receipts" inbox is **later**; extraction is a pure unit so the inbox can reuse it without rework |
| 2 | The **clerk picks the document type** by which form they open. The AI never switches PurInvoice ↔ Payment |
| 3 | **New documents only.** No capture on edit |
| 4 | Extraction fills **only empty fields**. A second, separate file is attached but does **not** re-extract; **↻ Read again** does that on purpose |
| 5 | **Contact:** match by TIN → BRN → name (the existing resolver); otherwise leave it blank for the clerk and show what was read. Never auto-create contacts |
| 6 | **Lines:** one detail line per receipt item. A good is seeded **only** by the proven safe rules; otherwise it is blank. No AI good-guessing |
| 7 | **The photo is kept** as a files-only Note on the saved document, using the note tray, the phone page and attachments (approach A). No new file store |
| 8 | **Separate AI settings for receipts** (`"llm_receipt"`). A blank field falls back to the shared `"llm"` setting **only on the same provider**; on another provider endpoint, model and key start blank. Admin-only, checked on the server. Bank Recon and Query are unchanged |
| 9 | Payment `funds_account`: the contact's sole funds account → else **Cash In Hand** when the receipt says cash and that account exists → else blank |
| 10 | SST given only as a total, and a non-zero rounding adjustment, each become a **separate line** with the good blank |
| 11 | Every warning is advisory. **Nothing blocks Save** except the forms' existing validation |
| 12 | **Picture not recognised** as a bill or receipt: the AI returns a short description of what it sees, which goes into the document's `descriptions` (when blank), with a warning. Nothing else is seeded |

## User flow

1. On **New Purchase Invoice** and **New Payment**, the header gets two buttons:
   - **📱 Scan**: the existing `PhoneQrComponent` QR, which opens the phone page on
     a tray (photo, or multi-page scan → PDF).
   - **📎**: pick or drop a JPEG / PNG / WebP / PDF on the desktop, for emailed or
     WhatsApp PDFs.
2. The file lands in the form's tray. The upload broadcast reaches the form (via
   `NoteFiles` listening), and a strip shows **"⏳ Reading receipt… (<model>)"**.
3. When extraction returns, empty header fields and lines are filled in, and the
   strip shows the token usage and cost (`LlmClient.format_usage/1`).
4. A **Receipt panel** beside the form shows:
   - the thumbnail (click to enlarge);
   - what was read: shop name, TIN, BRN, receipt no, date, total;
   - the warnings (see below);
   - the **totals check**: "Keyed RM x · Receipt RM y ✓", or red with the difference
     (using `EInvMetas.Prefill.variance/2` semantics, a tolerance of 0.01).
5. **Save** stores the document and attaches the tray as a 🧾 Receipt note in one
   transaction. **Cancel / leaving** discards the tray, as the note composer does
   (the 24 h `TrayPruner` catches the rest).

The first file into an empty tray triggers extraction. A multi-page bill is one
phone **Scan**, so it is one PDF and one extraction. Later files only attach.
**↻ Read again** asks which tray file to read and re-runs extraction. It still
fills only empty fields.

## Components

### 1. `Sys.llm_settings(company, profile)` (profile `:default | :receipt`)

- `:default` returns `"llm"` merged over the defaults (`llm-provider` "none", the
  rest ""), exactly what the three copies do today.
- `:receipt` returns `:default` with every **non-blank** `"llm_receipt"` field
  laid over it — when the receipt provider is blank or equals the shared one.
  On a different provider the non-blank fields are laid over the blank
  defaults instead, so another vendor's key, model or endpoint is never sent.
- The Company form's save handler writes either key only when
  `can?(user, :update_company, company)` — hiding the block is not a check.
- It replaces `load_llm_settings/1` in `bank_reconciliation_live/index.ex` and
  `query_live/form.ex`, and the `llm_defaults` merge in `company_live/form.ex`.
- **Company form:** a second block, **"AI for receipts / bills"**, with the same
  four inputs, saved to `"llm_receipt"`. Blank inputs show the inherited value as
  a placeholder. The API key placeholder is masked.

### 2. `LlmClient.call_with_image(settings, system, user, base64, media_type)`

- **Claude:** a `type: "image"` content block with `source.media_type`.
- **OpenAI-compatible (Gemini):** an `image_url` data URI.
- PDFs keep using `call_with_pdf/4`.
- `http_post/3` becomes swappable through app config
  (`:full_circle, :llm_http`, default the current `:httpc` function), so tests can
  stub replies. Behaviour does not change.

### 3. `FullCircle.Receipts.Extract.run(path, content_type, llm_settings)`

Returns `{:ok, %Extracted{}, usage}` or `{:error, reason}`. It knows nothing about
forms or LiveView.

**Model output contract:** strict JSON, with `null` for anything not visible:

```
supplier: {name, tin, brn, sst_no}
doc_no, date (YYYY-MM-DD), due_date
lines: [{description, quantity, unit_price, discount, tax_rate_percent, amount}]
subtotal, tax_total, rounding, total
payment_method: "cash" | "card" | "transfer" | "cheque" | null
e_invoice_uuid
recognized: true | false   (is this a bill / receipt / invoice at all?)
summary: string            (one sentence of what the picture shows, max 200 chars; always set)
```

**Prompt rules:**
- Malaysian dates are DD/MM/YYYY.
- Amounts are plain numbers, with no "RM" and no thousands separators.
- Tax is a percentage.
- Rounding is its own field, not a line.
- Handwritten cash-bill items are lines.
- Never guess: return null instead.

**Limits:** an image is refused when its base64 exceeds 5 MB (the AI's limit
is on the encoded payload); `max_tokens` 16_384; 90 s timeout.

**Code-side validation** (the model is never trusted):
- Every amount → `Decimal` and every date → `Date`. A value that does not parse
  becomes nil plus a warning. Accept `"RM 1,234.50"` and JSON wrapped in a
  ```` ```json ```` fence.
- **Arithmetic:** if Σ line amounts + tax_total + rounding differs from total
  by ≥ 0.01, warn "Receipt lines don't add up". `total` stays the anchor.
- **Date:** if it is in the future or more than 12 months old, warn.
- **No lines but a total:** make one line, description = supplier name (or
  "Receipt"), quantity 1, unit price = total − tax_total − rounding.
- **Not recognised:** `recognized == false`, or no total and no lines,
  gives `%Extracted{recognized: false}` with only `summary` kept, plus the
  warning "Not recognised as a bill or receipt". Prefill then seeds only
  `descriptions` = summary (truncated to 200 chars). This also covers a wrong
  photo, such as a delivery order, a cheque or a blurry shot.
- **Bad JSON:** retry once with "Reply with the JSON object only", then return
  `{:error, …}`.

`%Extracted{}` carries the parsed fields plus `warnings: [String.t()]`.

### 4. `FullCircle.DocPrefill` (refactor out of `EInvMetas.Prefill`)

Move these, unchanged, into a shared public module: `put_contact`,
`contact_warning`, `put_goods`, `seed_good`, `good_named_in`, `apply_good`,
`merge_good`, `seed_lines`, `to_decimal`. `EInvMetas.Prefill` calls them. The
seeded-line traps (`unit_multiplier` 0; LHDN or receipt qty into
`package_qty` **and** `quantity`; tax % ÷ 100) then live in one place. The
existing e-invoice prefill tests must pass **unchanged**.

### 5. `FullCircle.Receipts.Prefill.build(extracted, com, user, :pur_invoice_details | :payment_details)`

Returns `%{attrs, warnings, contact_ids: {tin, brn}, total}`, the same shape the
forms already handle for e-invoice seeds.

**Header:**

| Extracted | PurInvoice | Payment |
|---|---|---|
| `date` | `pur_invoice_date` | `payment_date` |
| `due_date` | `due_date` (else = date) | — |
| `doc_no` | `e_inv_internal_id` (the supplier's bill no; `pur_invoice_no` is our gapless PINV no) | in `descriptions` |
| supplier name + `doc_no` | — | `descriptions` = "<name> #<doc_no>" |
| `summary` (only when not recognised) | `descriptions` | `descriptions` |
| `total` | totals-check anchor | `funds_amount` + totals-check anchor |

**Contact:** `DocPrefill.put_contact` with the supplier role. A name-only match
or no match adds a warning that names the extracted name, TIN and BRN.

**Payment `funds_account_name`:**
1. `BillPay.sole_funds_account_name/2`, when the contact is resolved.
2. Else, when `payment_method == "cash"` and an account named exactly
   `Cash In Hand` exists in the company, use it.
3. Else blank.

**Lines:** one per extracted line through `DocPrefill.seed_lines`, then
`DocPrefill.put_goods` (the contact's sole good with its packaging; else a good
named in the description; else blank). Extra lines with the good blank:
- **"SST"** when `tax_total` > 0 and no line has a `tax_rate_percent`
  (amount = tax_total, tax_rate 0);
- **"Rounding adj."** when `rounding` ≠ 0.

**Warnings added here:**
- **Possible duplicate:**
  - PurInvoice: same contact + `e_inv_internal_id`.
  - Payment: same contact + `payment_date` + `funds_amount`.
  - Returned as `duplicate`, apart from `warnings`. Re-checked after the read
    merges into the form and on every change, against the form's current
    contact (the clerk may have picked one first).
- **Locked period:** the date falls in a locked accounting period
  (`.claude/skills/accounting-period-lock.md`).
- **Has an e-invoice:** a printed `e_invoice_uuid` matches a synced received
  e-invoice. The warning links to the e-invoice row and says to create the
  document from there instead.

### 6. Form changes (`payment_live/form.ex`, then `pur_invoice_live/form.ex`)

- **New assigns:** `receipt_tray_id`, `receipt_state`
  (`:idle | :reading | :done | :error | :off`), `receipt` (the extracted fields,
  thumbnail and warnings), and `receipt_task_ref`.
- Use `assign_new` where `mount_new` already sets seeds (the e-invoice trap).
- **Extraction runs** under `Task.Supervisor.async_nolink` with a 90 s timeout,
  and the result arrives in `handle_info`. A result for a stale ref is ignored.
- **Merging fills only blank fields:**
  - a header field is filled only if blank in the current params;
  - lines are added only when the form has no line with a good or an amount.
- **Save:**
  - **PurInvoice:** pass `extend_multi` to `Billing.create_pur_invoice/4`.
  - **Payment:** add the same optional `extend_multi` argument to
    `BillPay.create_payment`, mirroring PurInvoice.
  - The extension appends `Multi.run(:receipt_note, …)`, which calls
    `Notes.create_note(%{"subject_type" => type, "subject_id" => id,
    "title" => "🧾 Receipt", "tray_id" => tray_id}, com, user)`.
  - The document and its receipt therefore commit together. A failed save (period
    lock, validation, `:stale`) leaves the tray open, so the clerk re-saves without
    uploading again.
  - If the user lacks `:create_note`, the extension is skipped: the document saves
    and a `:warn` flash says the receipt was not attached.
- **After a successful save:** learn the extracted TIN/BRN
  (`learn_contact_identifiers`, logged "learnt from Receipt") **only** when the
  contact matched by TIN/BRN and the saved contact is that same contact. A
  name match, no match, or a contact the clerk picked instead learns nothing.
- A phone upload that arrives after Save follows the tray to its note (existing
  tray behaviour).

## Failure handling

| Case | Shown |
|---|---|
| AI provider "none" | 📱/📎 still attach; strip: "AI reading off — set it under Company → AI for receipts" |
| Timeout / HTTP / API error | "Couldn't read receipt: …" + ↻ Read again; the file stays in the tray |
| Bad JSON from the model | One automatic retry, then the error above |
| Unsupported file (e.g. HEIC) | Existing sniff → 422 path |
| Clerk leaves mid-read | The task's result is dropped; the tray is pruned in 24 h |
| Clerk edited fields during the read | Only empty fields are filled |

The receipt image goes to the company's configured AI provider, as bank statements
already do. There is no new consent setting.

## Testing

TDD, with no live AI calls in the suite (stubbed `:llm_http`).

- **`Sys.llm_settings/2`:**
  - field-by-field fallback;
  - `:default` matches the old merge;
  - Bank Recon and Query behave the same.
- **`LlmClient.call_with_image/5`:** the request body shape for Claude and
  OpenAI-compatible providers.
- **`Receipts.Extract`:**
  - clean JSON; fenced JSON; nulls; `"RM 1,234.50"`;
  - the arithmetic warning; the date warnings;
  - total-only → one line;
  - bad JSON → retry → error.
- **`DocPrefill`:** the existing e-invoice prefill tests are green and unchanged.
- **`Receipts.Prefill`:**
  - contact by TIN / BRN / name / none;
  - safe goods; SST and rounding lines;
  - tax % → fraction; `unit_multiplier` 0;
  - funds account order;
  - duplicates; locked period; e-invoice UUID match.
- **LiveView (Payment, then PurInvoice):**
  - tray upload broadcast → reading strip → fields filled;
  - typed input is kept;
  - a second file does not re-extract;
  - Save attaches a 🧾 note to the document;
  - a period-lock save failure keeps the tray;
  - AI-off state.
- **Manual:** a real phone with real receipts, Payment first, then PurInvoice.
  Report the measured hit rate for contact, total and lines on that sample.

## Build order

1. `Sys.llm_settings/2` + the Company form "AI for receipts / bills" block
2. `DocPrefill` refactor (e-invoice tests green)
3. `LlmClient.call_with_image/5` + swappable HTTP
4. `Receipts.Extract`
5. `Receipts.Prefill`
6. Payment form (handed over for manual testing)
7. PurInvoice form (handed over for manual testing)
8. `.claude/skills/receipt-capture.md` + a CLAUDE.md skills-list entry; update
   `e-invoice-bill-prefill.md` to point at `DocPrefill`

## Out of scope

- The captured-receipts inbox / queue (the next step; `Extract` is ready for it)
- Capture on editing an existing document
- Creating contacts or goods from a receipt
- AI-suggested goods
- Matching a captured Payment against outstanding PurInvoices
- Invoice / Receipt (sales side) capture
