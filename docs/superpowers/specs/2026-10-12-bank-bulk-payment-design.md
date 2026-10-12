# Bank bulk payment files: approved Payments → bank upload file

Date: 2026-10-12 · Revised 2026-10-12 after the max-effort plan review
Status: revision 2, awaiting spec review

## Why

Supplier payments are keyed twice: once as a `Payment` in FullCircle, again as
a transfer in the bank portal. Both banks in use (RHB Reflex, PB enterprise)
take a **bulk payment file** uploaded by a *maker* and approved by an
*approver* with a bank token. FullCircle should produce that file from the
Payments already entered, so the bank-side maker only uploads it and the
approver approves it. It should then read the bank's result file back, so the
books know which payments the bank actually made.

No Malaysian bank offers a self-serve payment API to a company this size;
host-to-host needs bank onboarding and would put money-moving credentials on
the server. The file route keeps the bank's own maker/approver control.

**Money rule:** every way a Payment could be paid twice must need a
deliberate, logged action by a manager or admin.

## Decisions (from the brainstorm and the review)

| # | Decision |
|---|---|
| 1 | **Supplier Payments only.** Salaries and statutory payments are out of scope |
| 2 | **The bank's approval is the approval.** FullCircle is the maker side: it picks Payments and produces the file. No new approval workflow on `Payment` |
| 3 | **One bank account per supplier**, stored on the contact |
| 4 | **Configurable layouts.** Bank file layouts and bank result-file layouts are data (versioned specs), not per-bank code. New layouts ship as JSON templates |
| 5 | **RHB Reflex Bulk Pay (CSV) and PB enterprise ECP Payment (fixed-width TXT)** are the two bundled payment templates. PB Bulk JomPAY is **not** in scope |
| 6 | **Remittance advice included**: matched invoice lines (RHB advice rows / PB e-mail description lines) and the bank's e-mail notice to the contact's e-mail(s). SMS notification is never used (PB charges per SMS) |
| 7 | **Payments are ticked by hand** on a batch screen. Only Payments dated on/after the profile's start date appear; none are pre-ticked |
| 8 | **Separate store** (`bank_file_formats`), not the statutory file-format table. The engine is shared |
| 9 | **Bank details are visible and editable only by admin and manager.** Batch work is admin/manager only. Saved SQL queries become admin/manager only |
| 10 | **"Paid outside file"**: a manager can dismiss a Payment that was paid by cheque or a manual transfer, so it leaves the batch list for good (undoable, logged) |
| 11 | **Batches have a lifecycle**: exported → submitted → completed / partly rejected, or voided. Voiding a submitted batch is admin only; a batch with an imported bank result can't be voided at all |
| 12 | **Line-level release** for payments the bank rejected or returned: only those Payments go back on the list; the rest of the batch stays locked as paid |
| 13 | **Download history**: every download is logged; "Download again" asks for a reason; voided batches can't be downloaded |
| 14 | **Duplicate warning** at batch creation: same supplier + same amount already in a live batch in the last 14 days needs an explicit "Create anyway" |
| 15 | **Bank result import**: PB's Payment Status Feedback (PSF) file is imported now and matched line by line by record ID. RHB's return file is added once the owner supplies a sample (its layout isn't published); until then RHB rejections use manual line release |
| 16 | **Company-local dates.** "Today" everywhere in this feature is the company's timezone date (`Asia/Kuala_Lumpur`), never UTC |
| 17 | **Out of scope:** PB's later IBG return file (layout not in the guide; returns use manual "returned by bank"), RENTAS, JomPAY, payroll files, sending SMS |

## Data model

### Contact bank details — new columns on `contacts`

| Column | Notes |
|---|---|
| `bank_code` | BIC, chosen from `FullCircle.BankPayment.Banks` |
| `bank_account_no` | digits only (non-digits stripped on cast) |
| `bank_account_name` | account holder name, at most 120 characters; the form pre-fills the contact name |
| `bank_details_changed_at` | `utc_datetime`, set whenever any of the three changes |

- All three of code / number / name are filled together or all blank.
- The account number length must be one of the bank's valid lengths.
- Cast only by `Contact.bank_changeset/2`. The existing `changeset/2` does
  **not** cast them, so the ordinary contact form can never write them.
- Saved through `Accounting.save_contact_bank/4`, guarded by
  `can?(user, :manage_contact_bank, company)` and the contact belonging to the
  company. It logs only real changes (cleared values logged as `(cleared)`)
  under entity **`contact_bank`**, never `contacts`, so the contact's ordinary
  log, which any contact editor sees, never shows account numbers.

### `FullCircle.BankPayment.Banks` (code, not a table)

`%{name, bic, lengths}` for every institution on PB's *IBG Participating
Financial Institutions* list (savings/current lengths, ranges expanded),
including YTL Digital Bank (Ryt Bank, `SCCHMYKL`), plus Public Bank `PBBEMYKL`
and Public Islamic Bank `PIBEMYK1`, which that list omits.

### `bank_payment_profiles` — one per paying bank GL account

| Column | Notes |
|---|---|
| `company_id` | |
| `account_id` | GL account, must be `account_type == "Bank"`; unique per company |
| `format_code` | e.g. `rhb_bulk_pay`, `pbb_ecp_payment` |
| `our_account_no` | digits only |
| `start_date` | Payments dated before this never appear on the batch screen |
| `params` | jsonb map of bank-specific header values (`corporate_id`, `corporate_name`, …) |

- Param names must be lowercase identifiers and **must not be a built-in
  variable name** (row, child or header variable). A param named like a row
  variable would otherwise replace that value on every line of the file.
  Built-in names are also dropped from params when building the header, as a
  second guard.

### `bank_file_formats` — versioned layouts

`code`, `name`, `effective_from`, `spec` (jsonb), `company_id`; unique
`(company_id, code, effective_from)`. The version used for a new batch is the
latest with `effective_from <= today`. "Replace this version" updates the row
in place; batches are unaffected because each batch keeps its own copy of the
spec.

### `bank_payment_batches`

| Column | Notes |
|---|---|
| `company_id`, `profile_id`, `format_id` | |
| `spec` | **copy of the spec used** — re-download renders from this, never from the live format |
| `payment_date` | chosen on the batch screen |
| `filename_stem`, `filename`, `seq` | `filename` unique per company |
| `header` | the header context used (dates as ISO strings) |
| `count`, `total` | |
| `status` | `exported`, `submitted`, `completed`, `partly_rejected`, `voided` |
| `submitted_by_id`, `submitted_at` | |
| `result_imported_at`, `result_filename` | |
| `void_reason`, `voided_by_id`, `voided_at` | |
| `created_by_id`, timestamps | |

### `bank_payment_batch_lines`

| Column | Notes |
|---|---|
| `batch_id`, `payment_id` | |
| `record_no` | from Postgres sequence `bank_payment_record_seq`; never reused |
| `status` | `pending`, `paid`, `rejected` |
| `live` | true while `pending` or `paid` in a non-voided batch |
| `bank_reason` | the bank's error text, or the manager's reason for a manual release |
| `released_by_id`, `released_at` | manual release / return |
| snapshot: `payment_no`, `doc_date`, `amount`, `bank_code`, `bank_account_no`, `bank_account_name`, `contact_name`, `email`, `reg_no`, `descriptions`, `advice` (jsonb list of `{doc_no, doc_date, amount}`) | |

- Partial unique index: one **live** line per Payment, so a Payment is in at
  most one non-voided, non-rejected line — it can never be paid twice by file.

### `bank_payment_dismissals` — "Paid outside file"

`payment_id` (unique), `company_id`, `user_id`, `note`, `inserted_at`. A
dismissed Payment never appears on the batch list and can't be batched. Undo
deletes the row. Both actions are logged. A Payment with a live line can't be
dismissed.

### `bank_payment_downloads`

`batch_id`, `user_id`, `reason` (blank for the first download),
`inserted_at`. One row per download.

### Payment locks

While a Payment has a live line (`pending` or `paid`), `BillPay.update_payment`
refuses changes to `funds_amount`, `contact_id`, `funds_account_id` and
`payment_date` with *"in bank batch <filename>"*. Payments have no delete path.

## Batch lifecycle

| From | Action | To | Who |
|---|---|---|---|
| — | Create file | `exported` | admin, manager |
| `exported` | Mark submitted to bank | `submitted` | admin, manager |
| `exported` | Void (reason) | `voided` | admin, manager |
| `submitted` | Void (reason, warning "the bank may already have paid this") | `voided` | **admin** |
| `exported`/`submitted` | Import bank result | `completed` (all paid) or `partly_rejected` | admin, manager |
| `submitted` | Release a line "rejected by bank" (reason) | stays; line `rejected` | admin, manager |
| `completed`/`partly_rejected` | Mark a paid line "returned by bank" (reason) | stays; line `rejected` | **admin** |
| `completed`/`partly_rejected` | Void | not allowed | — |

- Voiding sets every line `live = false`. Released/returned lines set
  `live = false` and `status = rejected` for that line only; the Payment
  returns to the batch list showing the last bank reason.
- When every line of a submitted batch is resolved by manual releases and a
  result import, the status follows the result.

### Downloads

- **Create file** downloads immediately and logs the first download.
- **Download again** needs a reason and warns *"this file may already be at
  the bank"*; it is logged. On a `submitted`, `completed` or `partly_rejected`
  batch it is admin only.
- **Voided batches can't be downloaded** (their Payments may be in a newer
  file).
- The history shows first download (who, when) and download count.
- RHB's filename carries the **upload date**. Re-downloading on a later day
  shows a warning: *"created on <date>; RHB expects today's date — void and
  create a new file if RHB refuses it."*

### Duplicate warning

Before saving, for each selected Payment: if a **live** line exists for the
same contact with the same amount on a batch created in the last 14 days, the
screen lists them and needs **Create anyway** to proceed.

## Engine changes (`FullCircle.FileSpec`)

All additions are optional keys. **Existing statutory specs must render
byte-for-byte the same**; the statutory tests are the guard.

1. **Allowed detail sources passed in** — statutory `["statutory_rows"]`, bank `["payments"]`.
2. **`computed`** — `name => expression`, evaluated per detail row from row and
   header variables (not from each other), before filter/sort/aggregates; usable
   in fields, filters and `sum()`. Any evaluation failure — including a raised
   exception — returns `{:error, msg}`, never crashes.
3. **`children`** on a detail section — child lines per item of a row list
   (`advice`), right after the parent; variables = parent + `advice_*`; not
   counted in `count()`/`sum()`.
4. **`quote: "csv"`** (delimited only).
5. **`allow`** on a field — character-class body; everything else removed before padding.
6. **`filename`** template — `{name}`, `{name:<strftime>}`, `{seq:N}`; inserted
   values and date output keep only `[A-Za-z0-9._-]`; a bad date pattern is an
   error, not a crash; a sequence wider than N digits is an error.
7. **`max_rows`** — the caller splits selections into chunks.
8. **New PayScript builtins**: `left`, `right`, `mid` (1-based), `num`, `mod`.
   PayScript's error labels handle any value type (dates included).

## Row data for bank files (`source: "payments"`)

| Variable | Value |
|---|---|
| `record_id` | line `record_no`, zero-padded to 12 |
| `payment_no` | Payment number |
| `doc_date` | **the Payment's date** (header `payment_date` is the batch's bank payment date; FileSpec merges header over rows, so the names must differ) |
| `amount` | `funds_amount` |
| `bank_code`, `account_no`, `account_name` | contact bank snapshot |
| `contact_name`, `reg_no`, `descriptions` | |
| `email` | first e-mail address on the contact (blank if over 70 chars) |
| `emails` | all addresses joined with `;` (contacts often hold several) |
| `advice` | matched invoices `{doc_no, doc_date, amount}` + one item per payment-detail line; a detail line without a description uses its good's name |
| `advice_text` | `"<doc_no> <DD/MM/YYYY> <amount>; …"` |

Header / footer / filename variables: `our_account_no`, `payment_date`,
`today` (company-local), `company_name`, `seq`, `batch_no`
(`YYYYMMDD` + 3-digit seq, ≤ 20 chars), and every profile param.

A bank spec declares its params (`"params": [...]`) and the allowed lengths of
our own account number (`"our_account_no_digits": [10]`). FileSpec ignores
both; the BankPayment context enforces them.

## Bundled payment templates (`priv/bank_file_templates/*.json`)

### `rhb_bulk_pay.json` — RHB Reflex Bulk Pay CSV

Source: rhbgroup.com/myreflex/premium/articles/article/bulk_csv_file.

- CSV, `quote: "csv"`, CRLF, `filename: "PAYMENT_{corporate_id}_{today:%d%m%Y}_{seq:3}.CSV"`,
  `params: ["corporate_id", "corporate_name"]`, `our_account_no_digits: [14]`,
  `max_rows: 300` (keeps the hash sum inside exact float range).
- **Allowed characters on every text field: `A-Za-z0-9 /?:().,'+-`** (RHB's
  list; `&` and `@` are rejected). `&` in names becomes `AND` before filtering.
  E-mail field: `A-Za-z0-9@._+;-`.
- Header `00` (19 fields), detail `10` (33 fields, e-mails at 28 using
  `emails`), advice `30` per item (9 fields; field 5 "invoice detail" is
  mandatory, so it falls back to the Payment number), footer `99` (10 fields).
- Hash: `computed.hash_part = num(right(account_no, 6)) * mod(floor(amount), 1000000)`;
  footer `floor((sum("hash_part") * 24 + 2994) / 285)`.

### `pbb_ecp_payment.json` — PB enterprise ECP Payment text

Source: PB enterprise *Bulk Payment & Bulk Payroll (PB ECP) User Guide* v1.2, §4.2, §6.

- Fixed width 19 / 781 / 51, CRLF,
  `filename: "{our_account_no}PM{payment_date:%d%m%y}{seq:2}.txt"`,
  `our_account_no_digits: [10]`.
- Detail per §6; payment type `PBB` for `PBBEMYKL`/`PIBEMYK1`, else `IBG`;
  amount in cents; e-mail description lines 1–5 from `advice_text`; e-mail field
  restricted to `A-Za-z0-9@._+-` (ASCII keeps byte widths exact).
- Hash: total cents + Σ first 4 digits of account numbers.

## Bank result import

### Result specs

A format may carry a top-level **`result`** key describing the bank's result
file, so result layouts are data too:

```json
"result": {
  "layout": "fixed",
  "header": {"identifier": "H", "filename": [10, 23]},
  "detail": {"identifier": "D", "record_id": [2, 16], "amount": [201, 18],
             "status": [259, 2], "reason": [261, 40]},
  "amount_in_cents": true,
  "success": ["01"]
}
```

Positions are 1-based `[from, length]`. A `"layout": "csv"` variant (column
indexes) is added when RHB's sample arrives.

### PB Payment Status Feedback (PSF)

Source: ECP guide §7. File `PSF<uploaded filename>.txt`; header 365, detail
300, footer 51 bytes. Header field 3 is the uploaded filename (23 chars —
shorter than `…01.txt`, so matching compares the name **without extension**,
trimmed, case-insensitive). Detail: record ID 2–17, amount 201–218 (cents),
status 259–260 (`01` successful, `02` failed), reason 261–300.

### Import rules

1. Upload the file on the Bank Batches screen. The batch is found by the
   result header's filename; it must be `exported` or `submitted`.
2. Each result line is matched to a batch line by record ID (trimmed). The
   amount must equal the line amount to the cent.
3. **Successful** → line `paid` (stays live, Payment locked for good).
   **Failed** → line `rejected`, `live = false`, `bank_reason` = the bank's
   reason; the Payment returns to the list.
4. **Unmatched record IDs, amount mismatches, or batch lines missing from the
   file** are listed; those lines change nothing.
5. Importing the same file again is a no-op; a result contradicting an
   earlier imported status is reported, not applied.
6. The batch becomes `completed` (all lines paid) or `partly_rejected`; it also
   counts as submitted. The import, its filename and every line change are logged.
7. The whole import is one transaction.

## Screens, flow and permissions

### Authorization

| Action | Roles |
|---|---|
| `:manage_contact_bank` (view + edit bank details) | admin, manager |
| `:manage_bank_payment_config` (profiles, formats) | admin |
| `:create_bank_payment_batch` (create, view, first download, download again of exported batches, mark submitted, void exported, release rejected line, import result, paid outside file) | admin, manager |
| `:admin_bank_payment_batch` (void submitted, mark paid line returned, download again after submission) | admin |
| `:create_query`, `:update_query`, `:delete_query`, `:execute_query` | **changed to** admin, manager |

### Contact form

A **Bank details** block (bank dropdown, account number, account holder name)
rendered only for `:manage_contact_bank`, saved separately from the contact,
with its own `contact_bank` log. It keeps its own state across re-renders of
the contact form.

### Settings → Bank Payments (admin)

- **Profiles** — bank GL account, format code, our account number, start date,
  params (`key=value` per line). Saving warns when the format's params or our
  account number length don't fit.
- **File formats** — like the statutory file-format pages: spec textarea,
  Replace this version, Preview (unsaved spec against the profile's currently
  eligible Payments — not batched, not dismissed), Load template.

### Payments → Bank Batches (admin, manager)

1. Pick a profile and a **payment date** (default company-local today; today …
   today + 59).
2. Eligible list: that GL account, dated on/after start date, amount > 0, no
   live line, not dismissed; newest first.
   - No bank details → greyed, not tickable.
   - Bank details changed in the last 30 days → ⚠ badge.
   - Previously rejected by the bank → shows the last bank reason.
   - **Paid outside file** button per row (note optional).
3. Ticking shows a running count and total.
4. **Create file** → pre-flight → duplicate warning (Create anyway) → batch(es)
   saved and downloaded (one file, or a zip when split at `max_rows`).
5. **Batch history**: created, filename, payment date, count, total, created
   by, status, first download, download count. Actions by status: Download
   again (reason), Mark submitted, Void (reason; explains it lets the Payments
   go into a new file), Import result, and per line Release rejected / Mark
   returned.
6. **Dismissed payments** view with Undo.

Payment index and form show an "In bank batch <filename>" tag on Payments with
a live line; the form shows a banner listing the locked fields.

### Sequence numbers

`seq` = 1 + the highest `seq` among the company's batches (any status,
including voided) with the same filename stem — banks refuse a filename already
uploaded. Computed under a lock on the profile row inside the batch transaction.

## Error handling

- **Pre-flight on Create file**, per selected Payment: bank details complete;
  account length valid for the bank; amount > 0 with at most 2 decimals; not
  dismissed; not already in a live line. Per batch: every declared param
  present; our account number length allowed by the format.
- **Inside the batch transaction**, after locking the profile, the selected
  Payments' `lock_version` is incremented (so an open Payment form can't save a
  stale amount) and they are re-read and re-checked; the file uses only the
  re-read values.
- Render errors, line-insert conflicts ("<Payment> was just batched by someone
  else") and other changeset errors roll the whole batch back with their own
  message.
- Payment lock violations return an error naming the batch.
- Audit log entries: batch created, downloaded, submitted, voided, result
  imported, line released/returned, payment dismissed/undismissed, profile
  saved, format saved, contact bank details changed (`contact_bank`).

## Testing

- **FileSpec**: one test per new feature; computed evaluation errors return
  errors; the existing statutory tests pass unchanged.
- **Golden files**: RHB (worked-example hash 164632936; a second case with
  cents and an amount ≥ RM1M: rows `112233374890` RM1,234,567.89 and
  `5000184560001` RM1,000.50 → footer `99,20261012001,2,1235568.39,7452364105,,,,,`;
  `&` → `AND`); PB (widths, positions, PBB/IBG, cents, hash).
- **Result import**: a PSF fixture with one success, one failure, one unknown
  record ID and one amount mismatch; re-import no-op; wrong batch status refused.
- **Context**: eligibility (start date, live line, dismissed, no bank details);
  `max_rows` split; seq counts voided batches; record IDs never repeat;
  lifecycle transitions and who may do each; voided batches not downloadable;
  re-download identical after the contact and the format change; duplicate
  warning; lock_version bump makes a stale Payment save fail; reserved param
  names refused; >2-decimal amounts refused; company-local dates.
- **LiveView**: tick → create → download; greyed / ⚠ / last-reason rows;
  Create anyway; paid outside file + undo; mark submitted; void rules;
  release line; result upload; contact bank block (manager yes, clerk no);
  query pages refused for clerk and supervisor.
- **Manual before go-live**: one RM1 batch per bank; import PB's PSF for it.

## Verify on first real upload (owner)

- PB footer totals in cents; PB account number left-aligned, space-padded (the
  "first 4 digits" hash depends on it); `PIBEMYK1` accepted as `PBB`; leave PB
  "Beneficiary ID checking" off.
- RHB accepts the file as generated; obtain an RHB return file sample.

## Go-live checklist (owner)

1. Ask RHB to enable the Reflex Bulk Pay module; note the 6-digit Corporate ID.
2. Confirm PB enterprise ECP Payment access for the maker user.
3. Fill supplier bank details (manager/admin).
4. Create a profile per paying bank account; load each template.
5. Run the RM1 test batch per bank; import PB's PSF; send an RHB return file
   sample to add RHB result import.
