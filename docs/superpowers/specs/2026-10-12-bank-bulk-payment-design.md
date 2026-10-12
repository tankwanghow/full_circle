# Bank bulk payment files: approved Payments → bank upload file

Date: 2026-10-12 · Status: approved in conversation, awaiting spec review

## Why

Supplier payments are keyed twice: once as a `Payment` in FullCircle, again as
a transfer in the bank portal. Both banks in use (RHB Reflex, PB enterprise)
take a **bulk payment file** uploaded by a *maker* and approved by an
*approver* with a bank token. FullCircle should produce that file from the
Payments already entered, so the bank-side maker only uploads it and the
approver approves it.

No Malaysian bank offers a self-serve payment API to a company this size;
host-to-host needs bank onboarding and would put money-moving credentials on
the server. The file route keeps the bank's own maker/approver control.

## Decisions (from the brainstorm)

| # | Decision |
|---|---|
| 1 | **Supplier Payments only.** Salaries and statutory payments are out of scope |
| 2 | **The bank's approval is the approval.** FullCircle is the maker side: it picks Payments and produces the file. No new approval workflow on `Payment` |
| 3 | **One bank account per supplier**, stored on the contact |
| 4 | **Configurable layouts.** Bank file layouts are data (versioned specs) rendered by the shared `FullCircle.FileSpec` engine, not per-bank code. New layouts ship as JSON templates |
| 5 | **RHB Reflex Bulk Pay (CSV) and PB enterprise ECP Payment (fixed-width TXT)** are the two bundled templates. PB Bulk JomPAY is **not** in scope |
| 6 | **Remittance advice included**: matched invoice lines (RHB advice rows / PB e-mail description lines) and the bank's e-mail notice to the contact's e-mail when set. SMS notification is never used (PB charges per SMS) |
| 7 | **Payments are ticked by hand** on a batch screen. Only Payments dated on/after the profile's start date appear; none are pre-ticked |
| 8 | **Separate store** (`bank_file_formats`), not the statutory file-format table. The engine is shared; the screens follow the statutory file-format pattern |
| 9 | **Bank details are visible and editable only by admin and manager.** Batch creation is admin/manager only. Saved SQL queries become admin/manager only |
| 10 | **Out of scope v1:** importing bank feedback/return files (PB PSF/IBG, RHB return file); RENTAS; JomPAY; payroll files |

## Data model

### Contact bank details — new columns on `contacts`

| Column | Notes |
|---|---|
| `bank_code` | BIC, chosen from `FullCircle.BankPayment.Banks` |
| `bank_account_no` | digits only (non-digits stripped on cast) |
| `bank_account_name` | account holder name; defaults to the contact name when first filled |
| `bank_details_changed_at` | `utc_datetime`, set whenever any of the three changes |

- All three of code / number / name are filled together or all blank.
- The account number length must be one of the bank's valid lengths
  (`Banks` table below), else "account number must be N digits for <bank>".
- Cast only by a new `Contact.bank_changeset/2`. The existing `changeset/2`
  does **not** cast them, so the ordinary contact form can never write them.
- Saved through `Accounting.save_contact_bank/4`, guarded by
  `can?(user, :manage_contact_bank, company)` (admin, manager). It writes an
  audit log under entity **`contact_bank`** (not `contacts`), so the contact's
  ordinary log, which any contact editor sees, never shows account numbers.

### `FullCircle.BankPayment.Banks` (code, not a table)

A list of `%{name, bic, lengths}` from PB's *IBG Participating Financial
Institutions* list (savings/current account lengths), plus Public Bank
`PBBEMYKL` and Public Islamic Bank `PIBEMYK1`, which that list omits. A
range like "5-17" expands to every length in it. Updating it is a code change;
the list changes rarely.

### `bank_payment_profiles` — one per paying bank GL account

| Column | Notes |
|---|---|
| `company_id` | |
| `account_id` | GL account, must be `account_type == "Bank"`; unique per company |
| `format_code` | e.g. `rhb_bulk_pay`, `pbb_ecp_payment` |
| `our_account_no` | the company's own account number at that bank |
| `start_date` | Payments dated before this never appear on the batch screen |
| `params` | jsonb map of bank-specific header values (`corporate_id`, `corporate_name`, `org_code`, …) |

### `bank_file_formats` — versioned layouts

Same shape and rules as `statutory_file_formats`: `code`, `name`,
`effective_from`, `spec` (jsonb), `company_id`; unique
`(company_id, code, effective_from)`. The version used is the latest with
`effective_from <= today` (download day), like statutory formats. Saving onto
an existing `(code, effective_from)` offers **Replace this version**.

### `bank_payment_batches`

| Column | Notes |
|---|---|
| `company_id`, `profile_id` | |
| `format_id` | the exact `bank_file_formats` version used (re-download uses it) |
| `payment_date` | chosen on the batch screen |
| `filename` | rendered filename, unique per company |
| `seq` | the sequence part of the filename |
| `count`, `total` | |
| `status` | `exported` or `voided` |
| `void_reason`, `voided_by_id`, `voided_at` | |
| `created_by_id`, timestamps | |

### `bank_payment_batch_lines`

| Column | Notes |
|---|---|
| `batch_id`, `payment_id` | |
| `record_id` | company-wide running serial, never reused (PB: "MUST not be reused") |
| `amount`, `bank_code`, `bank_account_no`, `bank_account_name`, `email`, `reg_no` | snapshot at export |
| `advice` | jsonb list of `{doc_no, doc_date, amount}` snapshot |

- A partial unique index allows a Payment in **at most one non-voided batch**:
  unique `(payment_id)` where the parent batch is `exported`. Implemented as a
  denormalised `live` boolean on the line (true while the batch is exported,
  set false on void) with `unique_index(:bank_payment_batch_lines, [:payment_id], where: "live")`.
- `record_id` comes from the existing gapless counter (`get_gapless_doc_id`,
  doc code `BankRecord`), so it is locked and never collides.

### Payment locks

While a Payment has a live batch line, `Payment` changesets reject changes to
`funds_amount`, `contact_id`, `funds_account_id` and `payment_date`, and
`delete` is refused, with the error *"in bank batch <filename>; void the batch
first"*. Enforced in the context save/delete path (one query for a live line),
not only by greying out the form.

## Engine changes (`FullCircle.FileSpec`)

All additions are optional keys. **Existing statutory specs must render
byte-for-byte the same**; the statutory test suite is the guard.

1. **Allowed detail sources passed in.** `validate/3` and `render/5` take the
   allowed `source` values. Statutory callers pass `["statutory_rows"]`, bank
   callers `["payments"]`. The existing 2/4-arity functions keep statutory
   behaviour.
2. **`computed`** — top-level map `name => expression`, evaluated per detail row
   (in key order, each may use earlier ones) before filters, sorting and
   aggregates. Usable in fields, filters and `sum("name")`.
3. **`children`** on a detail section — a list of child sections, each with
   `source` naming a list key on the row (`"advice"`) and `fields`. Rendered
   immediately after their parent line, one line per list item. A child row's
   variables are the parent row's plus the item's keys prefixed with the
   source name (`advice_doc_no`, `advice_doc_date`, `advice_amount`).
   Children do not count towards `count()` or `sum()`.
4. **`quote: "csv"`** (delimited mode only) — a value containing the delimiter,
   `"`, CR or LF is wrapped in `"…"` with inner quotes doubled.
5. **`allow`** on a field — a character-class body, e.g. `"A-Za-z0-9 .,/-"`;
   characters outside it are removed before padding.
6. **`filename`** — top-level template. `{name}` inserts a header value;
   `{name:%d%m%Y}` formats a date with that pattern; `{seq:N}` inserts the
   sequence zero-padded to N digits. Validation rejects unknown names.
7. **`max_rows`** — positive integer. The caller splits a selection into chunks
   of at most this many rows; the engine itself still renders one file.
8. **New PayScript builtins** (available to statutory scripts too):
   `left(text, n)`, `right(text, n)`, `mid(text, start, n)` (1-based),
   `num(text)` (digits → number; blank → 0), `mod(a, b)`. `left`/`right`/`mid`
   take text, so long account numbers never pass through floats.

Sums stay float. The largest term (RHB hash: 6 digits × 6 digits ≈ 10¹² per
row) is well inside exact float range for any realistic batch.

## Row data for bank files (`source: "payments"`)

Detail row variables:

| Variable | Value |
|---|---|
| `record_id` | the line's running serial |
| `payment_no`, `payment_date` | from the Payment |
| `amount` | `funds_amount` (number) |
| `bank_code`, `account_no`, `account_name` | contact bank snapshot |
| `contact_name`, `reg_no`, `email` | from the contact |
| `descriptions` | Payment descriptions |
| `advice` | list of `{doc_no, doc_date, amount}` from the Payment's transaction matchers (matched invoice doc no, date, match amount as a positive number) plus one item per payment-detail line (`descriptions`, payment date, line amount) |
| `advice_text` | the same list flattened: `"<doc_no> <DD/MM/YYYY> <amount>; …"` |

Header / footer / filename variables: `our_account_no`, `payment_date`,
`today`, `company_name`, `seq`, and every key in the profile's `params`.

## Bundled templates (`priv/bank_file_templates/*.json`)

### `rhb_bulk_pay.json` — RHB Reflex Bulk Pay CSV

Source: rhbgroup.com/myreflex/premium/articles/article/bulk_csv_file.

- `delimiter: ","`, `quote: "csv"`, `extension: "CSV"`, `line_ending: "\r\n"`.
- `filename: "PAYMENT_{corporate_id}_{today:%d%m%Y}_{seq:3}.CSV"`.
- Header `00`: file identifier `01` (Bulk Payment), `corporate_id`,
  `corporate_name`, `our_account_no`, payment date `DDMMYYYY`, file batch
  number (the filename stem), blanks/fillers for the rest (19 fields).
- Detail `10` (33 fields): payment type `10` (AutoCredit & IBG), `record_id`,
  amount `decimal:2`, `bank_code`, BOP `1`, `account_name`, `account_no`,
  ID indicator `05` + `reg_no` when set, recipient reference `payment_no`,
  other details from `descriptions`, notification `email`, fillers.
- Child `30` per `advice` item: invoice date `DDMMYYYY`, amount, invoice no,
  invoice detail.
- Footer `99`: batch number, `count()`, `sum("amount")`, hash total.
- `computed.hash_part = num(right(account_no, 6)) * mod(floor(amount), 1000000)`;
  hash total `floor((sum("hash_part") * 24 + 2994) / 285)`.
- Params required: `corporate_id` (6 digits from RHB), `corporate_name`.
- The bank must enable the Bulk Pay module first (request; up to 5 working days).

### `pbb_ecp_payment.json` — PB enterprise ECP Payment text

Source: PB enterprise *Bulk Payment & Bulk Payroll (PB ECP) User Guide* v1.2, §4.2 and §6.

- Fixed width, `line_ending: "\r\n"`, `extension: "txt"`.
- `filename: "{our_account_no}PM{payment_date:%d%m%y}{seq:2}.txt"`.
- Header (19): `H`, `our_account_no` (10), `payment_date` `YYYYMMDD`.
- Detail (781): `D`; `record_id` (16); payment type (3)
  `if(bank_code == "PBBEMYKL" or bank_code == "PIBEMYK1", "PBB", "IBG")`;
  `account_no` (20); `bank_code` (11); `account_name` (120); ID type `BR` +
  `reg_no` (2 + 29) when set; amount `cents` right/zero-padded (16);
  recipient reference `payment_no` (20); other details (20); `email` (70);
  e-mail 2, mobiles, joint fields blank; e-mail description lines 1–5 =
  `mid(advice_text, 1, 40)`, `mid(advice_text, 41, 40)`, … (5 × 40).
- Footer (51): `F`, `count()` (10), total amount in cents (20), hash total (20)
  = total amount + `sum("acct4")`, with `computed.acct4 = num(left(account_no, 4))`.
- Text fields use `allow` with PB's permitted characters.
- **Assumption to verify on first upload:** footer totals are in cents, like
  the detail amount.

## Screens, flow and permissions

### Authorization (new / changed)

| Action | Roles |
|---|---|
| `:manage_contact_bank` (view + edit bank details) | admin, manager |
| `:manage_bank_payment_config` (profiles, formats) | admin |
| `:create_bank_payment_batch`, `:void_bank_payment_batch`, view batches/re-download | admin, manager |
| `:create_query`, `:update_query`, `:delete_query`, `:execute_query` | **changed to** admin, manager |

The batch screen and re-download are admin/manager only, so full account
numbers are never shown to other roles anywhere.

### Contact form

A **Bank details** block (bank dropdown name → BIC, account number, account
holder name), rendered only for `:manage_contact_bank`. It saves through its
own event and `save_contact_bank/4`, separate from the main contact save, so a
clerk's contact edit cannot touch it. The block shows its own `contact_bank`
log.

### Settings → Bank Payments (admin)

- **Profiles** — index + form: bank GL account (Bank type), format code, our
  account number, start date, params as key/value rows. Saving warns when the
  current format's spec references a param the profile lacks.
- **File formats** — index + form modelled on the statutory file-format pages:
  code, name, effective from, spec textarea, **Replace this version**,
  **Preview** (renders the unsaved spec against a chosen profile's currently
  eligible Payments, nothing saved), **Load template** (inserts a bundled JSON
  from `priv/bank_file_templates/`).

### Payments → Bank Batch (admin, manager)

1. Pick a profile and a **payment date** (default today; must be today …
   today + 59 days).
2. Eligible list: Payments of that GL account, `payment_date >= start_date`,
   no live batch line, `funds_amount > 0`; newest first. Columns: date,
   Payment no, supplier, bank, account no, amount. Nothing ticked.
   - Supplier without bank details → row greyed, not tickable, "no bank details".
   - Bank details changed in the last 30 days → ⚠ badge with the change date.
3. Ticking shows a running count and total.
4. **Create file**: validates, saves the batch(es) and downloads. When the
   selection exceeds `max_rows`, several batches are created (consecutive
   seqs) and downloaded as one zip.
5. **Batch history** on the same page: created at, filename, payment date,
   count, total, created by, status. Actions: **Download again** (rebuilds from
   the saved lines and the saved format version) and **Void** (reason required,
   logged; frees the Payments).

Payment index and form show an "In bank batch <filename>" tag on Payments with
a live line; the locked fields render read-only.

### Sequence numbers

`seq` = 1 + the highest `seq` among the company's batches (any status,
including voided) whose filename, rendered with the seq part removed, equals
this one's. Banks refuse a filename that was already uploaded, so voided
batches still count. Computed under a lock on the profile row inside the batch
transaction.

## Error handling

- **Pre-flight on Create file**, per selected Payment: bank details complete,
  account length valid for the bank, amount > 0 and fits the amount field, and
  every param the spec uses exists on the profile. Failures list the Payment
  numbers with reasons; nothing is saved.
- **Render errors** (bad expression, value wider than a zero-padded field,
  unknown variable) show the engine message; nothing is saved.
- Batch creation is one `Ecto.Multi`: record IDs, seq, batch and lines commit
  together or not at all; the file is rendered inside the transaction and the
  transaction rolls back if rendering fails.
- **Concurrent batching** of the same Payment: the live-line unique index makes
  the second transaction fail; the user sees "Payment X was just batched by
  someone else" and the list refreshes.
- **Payment lock** violations return a changeset error naming the batch.
- Audit log entries: batch created, batch voided (with reason), profile saved,
  format saved, contact bank details changed (`contact_bank` entity).

## Testing

- **FileSpec**: one test per new feature (`computed`, `children`, `quote`,
  `allow`, `filename`, allowed sources, `left`/`right`/`mid`/`num`/`mod`);
  the existing statutory FileSpec and StatutoryConfig tests pass unchanged.
- **Golden files**: the bundled RHB template renders a fixed set of Payments to
  an exact expected CSV; the hash total formula is checked against RHB's
  published worked example (164632936). The PB ECP template renders to an
  exact expected TXT with a hand-computed hash.
- **Context**: eligibility (start date, live line, no bank details, zero
  amount); `max_rows` split; seq counts voided batches; `record_id` never
  repeats across void + re-batch; void frees Payments; Payment locks on
  update and delete; bank-details validation (all-or-none, account length);
  `changeset/2` ignores bank fields; authorization for every new action and
  the query permission change.
- **LiveView**: batch screen tick → create → download; greyed and ⚠ rows; void
  with reason; contact bank block hidden for clerk, editable for manager;
  query pages refused for clerk and supervisor.
- **Manual before go-live**: one small real batch per bank (e.g. RM1 to an
  own account at another bank) to confirm both hash totals and PB's cents
  convention in the footer.

## Go-live checklist (owner)

1. Ask RHB to enable the Reflex Bulk Pay module; note the 6-digit Corporate ID.
2. Confirm PB enterprise ECP Payment access for the maker user.
3. Fill supplier bank details (manager/admin).
4. Create a profile per paying bank account; load each template.
5. Run the RM1 test batch per bank.
