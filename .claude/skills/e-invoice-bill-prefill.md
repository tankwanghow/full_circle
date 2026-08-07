---
name: e-invoice-bill-prefill
description: Use when seeding a local document from a received LHDN e-invoice — Prefill.build with :purchase (PurInvoice/Payment) or :sales (Invoice/Receipt from received self-billed), contact resolution by TIN/BRN, good pre-fill, funds_amount, the total variance guard on forms, and quantity/packaging/tax traps in seeded lines.
---

# Seeding a Local Document from a Received E-Invoice

Received LHDN rows can create local docs via `?obj=<einvoice json>`:

| LHDN row | Side | Create | Prefill call |
|---|---|---|---|
| Supplier **Invoice** | `:purchase` (default) | PurInvoice, Payment | `Prefill.build(obj, com, user, :pur_invoice_details)` / `:payment_details` |
| **Self-billed Invoice** (buyer issued; we are the supplier) | `:sales` | Invoice, Receipt | `Prefill.build(…, :invoice_details, side: :sales)` / `:receipt_details` |

Entry points: list component buttons (`e_inv_list_*`) and the dual-lane **E-Invoice Queue** (`e_inv_queue_live`). Both navigate to the form with the same `obj` JSON.

**`FullCircle.EInvMetas.Prefill.build/4` (or `/5` with opts)** fetches the full document from LHDN, parses it, and returns:

- `attrs` — contact + detail lines + `e_inv_uuid` / `e_inv_internal_id`
- `payable` — LHDN `totalPayableAmount` (nil when zero/missing)
- `preview` — parsed body for the form preview panel
- `warnings` — contact unresolved / name-only match / fetch failure
- `contact_ids` / `supplier_ids` — `{tin, brn}` for `learn_contact_identifiers` after save
- `issue_date`

Callers only add their own field names (`pur_invoice_no` / `invoice_date` / `funds_amount`, etc.).

`PaymentDetail` is field-identical to `PurInvoiceDetail`; `ReceiptDetail` mirrors `InvoiceDetail` the same way. Traps below are **silent** — a divergent copy will not fail loudly.

For sync/match/reconcile see `e-invoice-sync.md`. For queue stages (needs bill vs needs invoice) see queue dual-lane behaviour. This skill is only the data-entry path.

A bill seeded here carries **no trading link** — `Prefill` knows nothing about grain trading. Clerks attach loads/drops from the form panel; see `grain-trading-desk.md`.

---

## Which side is which (do not mix)

**Purchase (`:purchase`)** — someone billed *you*. Contact is the **supplier** (`supplierTIN` / issuer). Goods use purchase accounts and `purchased_good_names`. Forms: PurInvoice, Payment.

**Sales (`:sales`)** — a **received self-billed** e-invoice: the *buyer* issued a self-bill naming you as supplier. You book **your sale** to that buyer. Contact is the **customer** (`buyerTIN` / `receiverTIN` / issuer on self-bill). Goods use sales accounts and `sold_good_names`. Forms: Invoice, Receipt.

**Never prefill Payment from a self-billed e-invoice the company *sent*.** Roughly 60% of payments carry an `e_inv_uuid`, but **1,733 of 1,826 are self-billed invoices the company issued**. For those the flow is the other way: `get_internal_document("Self-billed Invoice", "Sent", …)` finds a Payment by `payment_no` because the self-bill is submitted to LHDN using the payment’s own number. **The Payment exists first.**

Only ~92 payments (about 15/month, from 2026-01) come from a *received* supplier Invoice: direct expense paid immediately with no PurInvoice. **"New Payment"** is only for received **supplier** invoices (purchase lane). The sent listing / self-bill flow is not prefill.

---

## Payment / Receipt funds seeding

**Payment** (purchase, received supplier invoice):

- `funds_amount` ← LHDN payable (matched every received-matched payment checked)
- `funds_account` ← `BillPay.sole_funds_account_name/2` only when that supplier has only ever been paid from one account (**98.7% right, 56% coverage**). Most-recent is 92% — not good enough for a bank. (88 of 92 were `Cash In Hand`.)

**Receipt** (sales, received self-billed):

- `funds_amount` ← LHDN payable (same idea)
- No sole-funds-account prefill on sales yet (no `ReceiveFund.sole_funds_account_name`)

---

## Contact: identifiers first, name last

`Accounting.resolve_e_invoice_contact/4` tries `contacts.tax_id`, then `contacts.reg_no`, then the name with punctuation, spacing and case stripped. Returns `{contact, :tax_id | :reg_no | :name}` or `nil` — **the source matters**: TIN/BRN identifies the party; a name does not. Forms warn on `:name` and on `nil` (role label is Supplier or Customer).

`Accounting.learn_contact_identifiers/5` stamps TIN/BRN onto a contact missing them after save. **Never overwrite either field.** Contacts often keep the old ROC number ("178854-K") while LHDN sends the 12-digit SSM number; both are legitimate.

Measured on purchase data, weighted by bill volume: tax_id 93.7%, name 4.8%, unresolved 1.3%, reg_no 0.2%. Name-match warning is self-extinguishing after the first bill once TIN is learned.

Do **not** add abbreviation rules ("Bhd" ↔ "Berhad"). Data has near-collisions (e.g. Liberty General vs Liberty Insurance) that would silently attach the wrong party.

---

## Goods: seed only when safe

`Prefill` fills the good (pivot for account, tax code, unit). Rules, in order:

1. **Contact has only ever traded one good**  
   - purchase: `Billing.sole_purchased_good_name/2` / `purchased_good_names`  
   - sales: `Billing.sold_good_names/2` (sole when list length is 1)  
   — take good **and** packaging.
2. **Line description contains one of those good names** (longest match wins) — take good, **not** packaging.

Backtested over 12 months (purchase history):

| Rule | Coverage | Precision |
|---|---|---|
| Exactly one good | 14% | **98.2%** |
| Description contains good name | 4% | **95.9%** |
| Combined (as implemented) | 18.2% | **97.6%** |
| Always most frequent good | 99% | 73.3% ✗ |
| Best historical description match | 70% | 85% ✗ |

**A wrong good changes no amount** (qty/price from LHDN), so the variance guard cannot catch it. Aggressive rules are rejected on purpose.

Description matching is against **good names**, not historical descriptions. Annotations like `"argentine"` / `"foc"` map to many goods.

Sales path uses **sales** account / tax code fields on the good (`merge_good/4` with `:sales`).

---

## The three seeded-line traps

**1. `unit_multiplier` must stay 0.** `DetailHelpers.compute_detail_fields/1` sets `qty = package_qty * unit_multiplier` when multiplier > 0. Seeded lines have no real package_qty until packaging is chosen. Copying the good’s multiplier (as manual good-select does) zeroes the LHDN quantity.

**2. LHDN quantity is in the counterparty’s units.** Seed into **`package_qty` and `quantity`**. Quantity works until packaging is set; then multiplier completes the line.

**3. LHDN tax is a percentage; `tax_rate` is a fraction.** Document `5.0` → seed `0.05`. Divide by 100. Live 100× bug if missed; good-select overwrites and can hide it.

**Packaging is not seeded on description match** — first packaging on the good is often wrong for that supplier/customer. Sole-good path seeds packaging (~93% right on purchase history).

---

## The total variance guard (UI)

`Prefill.variance/2` returns `nil` when `|keyed − payable| < 0.01`, else the signed diff.

Forms assign `e_inv_payable` from `seed.payable` and show a strip under the lines:

| Form | Compare field | UI placement |
|---|---|---|
| PurInvoice | `pur_invoice_amount` | Under detail component (column-aligned) |
| Invoice | `invoice_amount` | Same pattern as PurInvoice |
| Payment | `payment_detail_amount` (not `funds_amount`) | Near action buttons |
| Receipt | `receipt_detail_amount` (not `funds_amount`) | Same pattern as Payment |

Green when in agreement; red with “out by” / “details out by” when not. **`funds_amount` is seeded from the same LHDN figure**, so only detail lines can drift — never compare variance to funds.

Anchor is `totalPayableAmount`: 96.8% exact match historically vs 91.4% net / 89.2% excl. tax.

**Zero LHDN total ⇒ no payable to show** (`payable/2` skips non-positive). Cargill-style `totalPayableAmount = 0.0` on valid invoices must not scream red.

This company often books sales tax as a **separate line** (good `Note`) with `tax_rate` 0 on purchase details — LHDN 5% tax will show red until that line is added.

---

## Gotchas

- `totalPayableAmount` in listing JSON is often a **string** (Jason quotes Decimals). `Prefill` parses via `to_decimal/1`.
- `mount_new/2` runs on disconnected and connected mount → **two** LHDN Get Document calls (60 RPM). Guard with `connected?(socket)` if it bites.
- Map literal: dynamic `detail_key =>` must come before shorthand keys when needed.
- E-invoice preview on Invoice/PurInvoice is fed from the fetch in `mount_new/2`. "Show E-Invoice" re-fetches; render only when `is_nil(@e_inv_preview)`.
- Assigns from `mount_new/2` must use `assign_new/3` later in `mount/3`, not bare `assign/2`, or seeds are wiped.
- After save, `maybe_learn_e_inv_contact_ids` uses `e_inv_supplier_ids` / `contact_ids` — name is historical; works for customer TIN/BRN too.

See also `liveview-computed-field-gotchas.md` for `:warn` flash and virtual fields from `changeset.params`.
