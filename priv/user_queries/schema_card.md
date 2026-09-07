# Query schema card

Write `fct_<table>` with **no arguments** and spaces around the name.
The app injects company id: `FROM fct_invoices i` → `FROM fct_invoices('uuid') i`.

Detail `fct_*` are **not** company-scoped. Always join them through the header.

Never query raw tables. Never use `fct_users`, `fct_logs`, `fct_company_user`, `fct_gapless_doc_ids`.

## Trade debtors / creditors

"List trade debtors / customer balances / AR as of DATE" means **contacts**, not a GL account named Trade Debtors.

```sql
SELECT c.name, SUM(t.amount) AS balance
FROM fct_transactions t
JOIN fct_contacts c ON c.id = t.contact_id
WHERE t.doc_date <= DATE '2026-06-30'
GROUP BY c.name
HAVING SUM(t.amount) <> 0
ORDER BY c.name
```

Default seeded control accounts are `Account Receivables` and `Account Payables`.
**Never invent** `Trade Debtors` or `Trade Creditors`. If the user wants the GL control
total, use a name from the company account list (or `a.name ILIKE '%receivable%'`),
not an English textbook name.

Creditors: same query, `HAVING SUM(t.amount) < 0` (or list all non-zero).

## Amounts (virtual — not stored)

- `invoice_amount`, `pay_slip_amount`, detail `amount` / `tax_amount` are computed in LiveView.
- Document totals: `fct_transactions.amount` (signed) by `doc_type` + `doc_no` / `doc_id`.
- Line goods: `quantity * unit_price` on `fct_invoice_details` (and the same on pur/receipt/payment details). `discount` is a stored field — do not assume % vs amount.

## Dates

Prefer business dates: `invoice_date`, `due_date`, `receipt_date`, `payment_date`, `journal_date`, `doc_date`, `note_date`, `slip_date`, `statement_date`, `har_date` (harvests), `move_date` (movements). Do not filter on `inserted_at` unless asked.

## Joins

```
fct_invoices.contact_id            → fct_contacts
fct_invoice_details.invoice_id     → fct_invoices
fct_invoice_details.good_id        → fct_goods
fct_invoice_details.account_id     → fct_accounts
fct_invoice_details.tax_code_id    → fct_tax_codes
fct_invoice_details.package_id     → fct_packagings

fct_pur_invoices.contact_id        → fct_contacts
fct_pur_invoice_details.pur_invoice_id → fct_pur_invoices
  (good/account/tax_code/package same as invoice details)

fct_credit_notes.contact_id        → fct_contacts
fct_credit_note_details.credit_note_id → fct_credit_notes
fct_debit_notes.contact_id         → fct_contacts
fct_debit_note_details.debit_note_id → fct_debit_notes

fct_receipts.contact_id            → fct_contacts
fct_receipts.funds_account_id      → fct_accounts
fct_receipt_details.receipt_id     → fct_receipts
fct_received_cheques.receipt_id    → fct_receipts

fct_payments.contact_id            → fct_contacts
fct_payments.funds_account_id      → fct_accounts
fct_payment_details.payment_id     → fct_payments

fct_journals — lines are fct_transactions where doc_type = 'Journal' and doc_id = journal.id

fct_transactions.account_id        → fct_accounts
fct_transactions.contact_id        → fct_contacts
fct_transaction_matchers.transaction_id → fct_transactions
fct_transaction_matchers.doc_id/doc_type → matching receipt/payment/cn/dn header

fct_bank_statement_lines.account_id → fct_accounts
fct_bank_statement_balances.account_id → fct_accounts

fct_employees — fct_salary_notes.employee_id, fct_pay_slips.employee_id
fct_salary_notes.pay_slip_id       → fct_pay_slips
fct_salary_notes.salary_type_id    → fct_salary_types
fct_pay_slips.funds_account_id     → fct_accounts

fct_goods.sales_account_id / purchase_account_id → fct_accounts
fct_packagings.good_id             → fct_goods

fct_fixed_assets.asset_ac_id       → fct_accounts
fct_fixed_asset_depreciations / fct_fixed_asset_disposals → parent fixed_asset

fct_harvests.employee_id           → fct_employees
fct_harvest_details.harvest_id     → fct_harvests
fct_harvest_details.flock_id       → fct_flocks
fct_harvest_details.house_id       → fct_houses
fct_movements.flock_id / house_id  → fct_flocks / fct_houses

fct_egg_stock_days — fct_egg_stock_day_details.egg_stock_day_id
fct_egg_stock_day_details.contact_id → fct_contacts

fct_trading_trips.transport_agent_id → fct_contacts
fct_trading_trip_loads.trip_id     → fct_trading_trips
fct_trading_trip_drops.trip_id     → fct_trading_trips
fct_trading_trip_loads.good_id / location_id / supply_position_id
fct_trading_trip_drops.good_id / location_id / sales_position_id / invoice_id
fct_trading_supply_positions.supplier_id → fct_contacts
fct_trading_sales_positions.customer_id  → fct_contacts
fct_trading_locations.contact_id   → fct_contacts
```

## Useful stored columns

- contacts: name, category, address1, address2, city, state, zipcode, country, reg_no, tax_id, email, phone
- accounts: name, account_type, descriptions
- invoices: invoice_no, invoice_date, due_date, descriptions, contact_id
- transactions: doc_type, doc_date, doc_no, doc_id, particulars, contact_particulars, amount, reconciled
- employees: name (and other HR fields on the row)
- salary_notes: note_no, note_date, quantity, unit_price, descriptions
- pay_slips: slip_no, slip_date, pay_month, pay_year

## Examples

Debtors-style listing (who, what doc, when):

```sql
SELECT c.name, i.invoice_no, i.invoice_date, i.due_date
FROM fct_invoices i
JOIN fct_contacts c ON c.id = i.contact_id
WHERE i.invoice_date >= DATE '2025-01-01'
```

GL movement on an account:

```sql
SELECT t.doc_date, t.doc_type, t.doc_no, t.particulars, t.amount
FROM fct_transactions t
JOIN fct_accounts a ON a.id = t.account_id
WHERE a.name = 'Trade Debtors'
  AND t.doc_date BETWEEN DATE '2025-01-01' AND DATE '2025-12-31'
ORDER BY t.doc_date, t.doc_no
```
