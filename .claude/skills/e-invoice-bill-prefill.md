---
name: e-invoice-bill-prefill
description: Use when working on creating a PurInvoice or a Payment from a received LHDN e-invoice — the shared FullCircle.EInvMetas.Prefill module, supplier resolution by TIN/BRN, good pre-fill from supplier history or line description, funds-account pre-fill, the total variance guard, and the quantity/packaging/tax traps in seeded lines.
---

# Seeding a Purchase Document from a Received E-Invoice

"New Pur Invoice" and "New Payment" on a received e-invoice row
(`e_inv_list_live/index_received_component.ex`) navigate to
`/PurInvoice/new?obj=<einvoice json>` or `/Payment/new?obj=…`. Both forms call
**`FullCircle.EInvMetas.Prefill.build/4`**, which fetches the full document from
LHDN, parses it, and returns seeded attrs plus the payable, the preview and any
warnings. The caller supplies only its own field names — `pur_invoice_no` /
`pur_invoice_date` / `due_date`, or `payment_no` / `payment_date` /
`funds_amount`.

One implementation is deliberate: `PaymentDetail` is field-identical to
`PurInvoiceDetail`, down to the same `validate_required` list, so every rule and
every trap below applies to both — and the traps are **silent**, so a divergent
copy would not fail loudly.

For the sync/match/reconcile side of e-invoices see `e-invoice-sync.md`. This
skill is only about the data-entry path.

## Payment only makes sense for *received* Invoices

Roughly 60% of payments carry an `e_inv_uuid`, but **1,733 of 1,826 are
self-billed invoices the company issued**, not supplier invoices. For those the
flow runs the other way: `get_internal_document("Self-billed Invoice", "Sent", …)`
finds a Payment by `payment_no`, because the self-bill is submitted to LHDN
using the payment's own number. **The Payment exists first — never prefill one
from a self-billed e-invoice.**

Only ~92 payments (about 15/month, a practice that started 2026-01) come from a
received supplier Invoice: a direct expense paid immediately with no PurInvoice,
91 of 92 carrying detail lines rather than matchers. The scoping is structural —
"New Payment" appears only on the *received* listing; the sent listing offers
New Invoice / New Receipt.

Payment-specific seeding:

- `funds_amount` ← the LHDN payable. It equalled `funds_amount` on every
  received-matched payment checked.
- `funds_account` ← `BillPay.sole_funds_account_name/2`, only when the supplier
  has only ever been paid from one account: **98.7% right, covering 56%** of
  payments. Taking the most recently used account instead is 92% right, which is
  not good enough for choosing a bank. (88 of the 92 are `Cash In Hand`.)

## Supplier: identifiers first, name last

`Accounting.resolve_e_invoice_contact/4` tries `contacts.tax_id`, then
`contacts.reg_no`, then the name with punctuation, spacing and case stripped.
It returns `{contact, :tax_id | :reg_no | :name}` or `nil` — **the source
matters and must not be discarded**: a TIN or BRN identifies the party outright,
a name does not, so the form warns on `:name` and on `nil`.

`Accounting.learn_contact_identifiers/5` then stamps the TIN and BRN onto a
contact that is missing them, so a supplier is hand-picked once and resolves on
identifier forever after. **Never overwrite either field.** Contacts commonly
hold the old ROC registration number ("178854-K") while LHDN sends the new
12-digit SSM number ("198901001548"); both are legitimate and the local one is
what the rest of the business uses.

Measured on real data, weighted by bill volume: tax_id 93.7%, name 4.8%,
unresolved 1.3%, reg_no 0.2%. The name-match warning is self-extinguishing —
every name-matched contact had a blank tax_id, so it stops warning after the
first bill.

Do **not** try to close the name gap with abbreviation rules ("Bhd" ↔
"Berhad"). The data contains `Liberty General Insurance Berhad` alongside a
local `Liberty Insurance Berhad`; a rule loose enough to merge those is loose
enough to attach a bill to the wrong supplier silently.

## Goods: seed only when it is safe

`Prefill` fills the good, which is the pivot field — choosing it carries the
purchase account, tax code, unit and multiplier with it. Two rules, in order:

1. **Supplier has only ever sold one good** (`Billing.sole_purchased_good_name/2`)
   — take it, and take its packaging too.
2. **The line description names one of the goods bought from them before**
   (`Billing.purchased_good_names/2`, longest match wins so "Wheat Brans" cannot
   shadow "Wheat Pollard") — take the good but **not** the packaging.

Backtested over 12 months, predicting only from strictly earlier history:

| Rule | Coverage | Precision |
|---|---|---|
| Supplier has exactly one good | 14% | **98.2%** |
| Description contains a good name | 4% | **95.9%** |
| Combined (as implemented) | 18.2% | **97.6%** |
| Always take the most frequent good | 99% | 73.3% ✗ |
| Best-matching historical description | 70% | 85% ✗ |

**A wrong good changes no amount**, because quantity and price come from LHDN —
so the total variance guard cannot catch it and nothing downstream will. That is
why the aggressive rules are rejected despite their coverage.

Description matching works against **good names**, not against historical
descriptions. Descriptions here are frequently annotations rather than product
names — `"argentine"` maps to Maize, Soybean Meal Hi Pro *and* Soybean Meal Low
Pro across 878 lines; `"foc"` maps to four vaccines; `"sales tax 5%"` maps to
Maize or Note. Matching them is ~85% accurate *at any similarity threshold,
including 0.99*, because the key genuinely is not unique. Containment against
the goods master is 96%.

## The three seeded-line traps

**1. `unit_multiplier` must stay 0.** `DetailHelpers.compute_detail_fields/1`
computes `qty = package_qty * unit_multiplier` whenever the multiplier is
positive, and a seeded line has no `package_qty`. Copying the multiplier from
the good — which is what the manual good-select handler does — silently zeroes
the quantity LHDN sent. Verified: good `AA-Tray` (140pcs/Bundle) went from
qty 1000 / RM1150 to qty 0 / RM0.

**2. LHDN quantity is in the supplier's units, not the good's stock unit.**
`WHEAT POLLARD 55KG` arrives as quantity 550 at price 690 — that is 550 *bags*,
= 30.25 Mt, = RM20,872.50, not 550 × 690. So the quantity is seeded into
**`package_qty` as well as `quantity`**: quantity is used while no packaging is
set, and the moment a packaging with a multiplier is chosen the line completes
without retyping.

**3. LHDN tax is a percentage, `tax_rate` is a fraction.** The document reports
`5.0` for 5%; `pur_invoice_details.tax_rate` is on the same scale as
`tax_codes.rate` (`0.06` for 6%). Divide by 100 when seeding. This was a live
100× bug, masked only because picking a good overwrites the field.

**Packaging is not seeded on a description match.** The description names the
product, never the pack size, and `Product.get_good_by_name/3` returns the
good's *first* packaging, which is often not the one this supplier uses:
`Wheat Pollard` defaults to `Unweighted Bag` while 282 of its 283 real lines
used `55kg/Bag`. Leaving it blank makes the required-field error force a
deliberate choice. (On the sole-good path the packaging is seeded; it is right
93% of the time overall.)

## The total variance guard

The parsed `total_payable_amount` is displayed under the document total, green
when the keyed lines agree and red with the difference when they do not
(`Prefill.variance/2`). On a Payment it is compared against
`payment_detail_amount`, not `funds_amount` — the latter is seeded from the same
LHDN figure, so only the lines can drift. It is
the right anchor: 96.8% of historical bills match it exactly, versus 91.4% for
`totalNetAmount` and 89.2% for `totalExcludingTax`.

**A zero LHDN total means "no figure to compare", not a discrepancy.** One
supplier (Cargill) publishes `totalPayableAmount = 0.0` on genuinely valid
invoices — 74 of 2558 bills. Without that guard every one of them screams. With
it, 9 bills in 2558 (0.35%) show a real variance.

Note that this company books sales tax as a **separate line** using the good
`Note` rather than via a tax code — all 13,181 purchase detail lines have
`tax_rate` 0. So an invoice where LHDN charges 5% will legitimately show red
until that line is added.

## Gotchas around the edges

- `totalPayableAmount` survives the JSON round-trip from the listing as a
  **string**, not a number — Decimal's Jason encoder quotes it. Parse
  accordingly or the comparison silently disappears.
- `mount_new/2` runs on both the disconnected and the connected mount, so each
  click costs **two** LHDN Get Document calls (60 RPM limit). Guard with
  `connected?(socket)` if this ever matters.
- A map literal cannot put `key: value` shorthand before a dynamic `key => value`
  entry, which `Prefill` needs for `detail_key`. The dynamic entry comes first.
- The e-invoice preview panel below the form is fed from the document already
  fetched in `mount_new/2`. The "Show E-Invoice" button re-fetches; it renders
  only `when is_nil(@e_inv_preview)`, so it hides itself.
- Anything assigned in `mount_new/2` must be re-assigned with `assign_new/3`,
  not `assign/2`, further down `mount/3` — otherwise the later call overwrites
  the seeded value.

See also `liveview-computed-field-gotchas.md` for the `:warn` flash kind and how
virtual fields render from `changeset.params`.
