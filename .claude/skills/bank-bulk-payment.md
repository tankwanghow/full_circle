---
name: bank-bulk-payment
description: Use when changing bank payment files (RHB Reflex Bulk Pay, PB enterprise ECP), bank file format or result specs, supplier bank details on contacts, bank batches and their lifecycle, paid-outside-file dismissals, the Bank Batches screen, or the FileSpec features computed/children/quote/allow/filename/max_rows.
---

# Bank Bulk Payment Files

Supplier `Payment`s → a bank upload file that the bank's maker uploads and the
bank's approver approves. FullCircle is the maker side only; the bank's own
approval is the approval. Spec: `docs/superpowers/specs/2026-10-12-bank-bulk-payment-design.md`.
Context: `FullCircle.BankPayment` (`lib/full_circle/bank_payment.ex`).

**Money rule:** every way a Payment could be paid twice must need a deliberate,
logged manager/admin action. Keep it that way when changing anything here.

## Contracts

- **Row vs header variables.** `FileSpec.prepare_rows/2` merges the header
  context *over* each row, so names must not collide. The Payment's own date is
  `doc_date`; `payment_date` is the batch's bank payment date (header).
- **Reserved names** (`BankPayment.reserved_variables/0`): row, child
  (`advice_*`) and header variables. Profile params and `computed` columns may not use them — a param
  named `bank_code` would overwrite every line's bank. Also dropped in
  `header_ctx/3` as a second guard.
- **Bank-only spec keys** (FileSpec ignores them; `BankPayment.validate_spec/1`
  checks them): `params` (profile params the layout needs),
  `our_account_no_digits` (allowed lengths of our account number), `result`
  (bank result-file layout).
- **`record_id`** = `record_no` from Postgres sequence `bank_payment_record_seq`,
  zero-padded to 12. Never reused (PB requires it), even across voided batches.
- **Sequence numbers** count every batch with the same filename stem,
  **including voided** — banks refuse a filename already uploaded.
- **`batch_no`** header = company-local `YYYYMMDD` + 3-digit seq (RHB header/footer).
- **"Today"** is always `BankPayment.today(company)` (company timezone), never
  `Date.utc_today()` — before 08:00 MYT UTC is still yesterday.

## Layouts

| Bank | Template | Notes |
|---|---|---|
| RHB Reflex Bulk Pay | `priv/bank_file_templates/rhb_bulk_pay.json` | CSV, `quote: "csv"`; header 00 (19 fields), detail 10 (33; e-mails at 28 via `emails`), advice 30 (9; field 5 mandatory → falls back to payment no), footer 99 (10). Text fields allow only `A-Za-z0-9 /?:().,'+-`; `&` → `AND` first. Filename carries the **upload** date. `max_rows: 300` keeps the hash exact in floats |
| PB enterprise ECP Payment | `priv/bank_file_templates/pbb_ecp_payment.json` | Fixed width 19/781/51 (guide §6). `PBB` for `PBBEMYKL`/`PIBEMYK1`, else `IBG`. Amount in cents. 5×40 e-mail description lines from `advice_text`. E-mail field ASCII-only so byte widths stay exact |

- **RHB hash:** `floor((Σ last6(account_no) × last6(int(amount))) × 24 + 2994) / 285)`
  (`computed.hash_part`). RHB's worked example → 164632936 (golden test).
- **PB hash:** total cents + Σ first 4 digits of every account number (`computed.acct4`).

## Batch lifecycle

| From | Action | To | Who |
|---|---|---|---|
| — | Create file | `exported` | admin, manager |
| `exported` | Mark submitted | `submitted` | admin, manager |
| `exported` | Void (reason) | `voided` | admin, manager |
| `submitted` | Void (reason) | `voided` | **admin** |
| `exported`/`submitted` | Import bank result | `completed` / `partly_rejected` (stays `submitted` while lines are pending) | admin, manager |
| `submitted` | Release a pending line "rejected by bank" | line `rejected` | admin, manager |
| `completed`/`partly_rejected` | Mark a paid line "returned" | line `rejected` | **admin** |
| `completed`/`partly_rejected` | Void | not allowed | — |
| any batch with an imported result or a paid line | Void | not allowed (even if still `submitted`) | — |

Every status change locks the batch row (`FOR UPDATE`) and re-checks the rule on
the locked row; void never takes `live` off a `paid` line. Dismissal locks the
Payment row, which batch creation also locks.

## Money guards (do not weaken)

- Partial unique index `bank_payment_batch_lines_one_live_per_payment`: one
  **live** line per Payment (`live` = pending or paid in a non-voided batch).
- Batch creation, inside one transaction: lock the profile row → bump the
  selected Payments' `lock_version` (open forms then save stale) → re-read and
  re-run pre-flight → insert batch + lines → render (rollback on any error).
- Each batch stores its own **spec copy** and **header**; lines snapshot
  everything rendered. Re-download never reads the live format, contact or Payment.
- **Voided batches can't be downloaded.** A second download needs a reason;
  after submission only an admin may download again. Every download is logged
  in `bank_payment_downloads`.
- Duplicate warning (same supplier + amount in a live line within 14 days, or
  twice in one selection) needs `force: true` ("Create anyway").
- `BillPay.update_payment/4` refuses changes to `funds_amount`, `contact_id`,
  `funds_account_id`, `payment_date` while a line is live
  (`BankPayment.assert_payment_unlocked/2`). Payments have no delete path.
- "Paid outside file" (`bank_payment_dismissals`) excludes a Payment from the
  list and from batching; a Payment with a live line can't be dismissed.

## Bank result import

`BankPayment.import_result/3` finds the batch by the result header's filename
(compared **without extension**, case-insensitive — PB's header keeps only 23
chars), matches lines by record id, and requires the amount to the cent.
A status in `success` → `paid` (locked for good); a status in `failure` →
`rejected`, `live = false`, `bank_reason` set. **Any other status** (blank,
"processing", garbled) is reported as unrecognised and changes nothing — the
result spec must list both `success` and `failure` codes. Unknown ids,
unreadable or mismatched amounts, a record id repeated in the same file (only
the first counts) and contradictions with an earlier status are reported, never
applied. Re-importing is a no-op.
Result layouts are data (`result` key, `Result.parse/2`, `"layout": "fixed"`,
1-based `[from, length]`). PB PSF positions: guide §7.

## Supplier bank details

Columns on `contacts` (`bank_code` BIC, `bank_account_no` digits, `bank_account_name`
≤ 120, `bank_details_changed_at`). Written **only** by `Contact.bank_changeset/2`
via `Accounting.save_contact_bank/4` (admin/manager); `Contact.changeset/2` never
casts them. Logged under entity **`contact_bank`**, never `contacts` (the contact
log is visible to every contact editor). Account length is checked against
`FullCircle.BankPayment.Banks`. Saved SQL queries are admin/manager only
because they can read these columns.

## Verify on first real upload

- PB footer totals in cents; PB account number left-aligned, space-padded (the
  first-4-digits hash depends on it); `PIBEMYK1` accepted as `PBB`; leave PB
  beneficiary ID checking off.
- Get a real RHB return file and add a `"layout": "csv"` result spec for RHB.

## Gotchas

- FKs from batches/lines/profiles CASCADE only so company deletion works. Never
  add a delete path for formats, profiles or Payments without revisiting batch
  history first.
- LiveView result upload: the input's form must bind `phx-change`
  (see `liveview-upload-gotchas.md`); a DOM assertion pins it.
