# Multi-receipt capture: many receipts → one Payment

Date: 2026-10-11 · Status: approved in conversation, awaiting spec review
Builds on: `2026-10-07-receipt-capture-design.md` (contract in
`.claude/skills/receipt-capture.md`).

## Why

Receipt capture reads **one** document per file. When a photo or scanned PDF
holds several receipts, they are squashed into one read. The case to serve is
a **salesperson's fuel claim**: one Payment to the salesperson, made up of
many receipts from different stations and dates. These come as one photo of
several receipts, or as a multi-page Scan PDF with several receipts per page.

## Decisions (from the brainstorm)

| # | Decision |
|---|---|
| 1 | **Payment only.** A Purchase Invoice is for one supplier's bill. On a PurInvoice the first recognised document is used and the rest are ignored, with a warning |
| 2 | **One AI read returns a list.** The prompt asks for `{"documents": [ … ]}`, one entry per receipt or bill, with today's fields per entry. A reply in today's single-object shape is read as a list of one |
| 3 | **A document can span pages.** A bill that continues across pages ("Page 1 of 3", lines carried over, total on the last page) is **one** entry. Separate receipts are separate entries, whether they share a page or not |
| 4 | **One file per read**, as today: a photo or one (multi-page) PDF. Later files in the tray still only attach. ↻ Read again still re-reads the first file |
| 5 | **One receipt read → today's behaviour exactly** (payee, item lines, SST/rounding lines, funds account, duplicate check, TIN learning) |
| 6 | **2+ receipts read → the payee is never filled.** For a claim the payee is the salesperson, not the stations. The clerk picks the payee, before or after the read; the blank-only merge never overwrites one already picked |
| 7 | **2+ receipts → one Payment line per receipt**, not per item. Sorted by receipt date, then by the order read |
| 8 | **Per-receipt duplicate warning** for 2+ receipts: an earlier Payment line with the same receipt no and amount. Advisory only |
| 9 | **At most 40 receipts per read.** Beyond 40, the first 40 are used and a warning tells the clerk to split the claim |
| 10 | Every warning stays advisory. Nothing new blocks Save |
| 11 | **Mixed claims (fuel, tolls, hotel…):** the AI tags each receipt with a fixed **kind** — Fuel, Toll, Parking, Hotel, Meal, Transport, Other. The kind leads the line text |
| 12 | **The good is learnt from past claims, per kind.** A line of kind K takes the good, account and tax code of the most recent saved Payment line whose text starts with `"K · "` and has a good. Never for Other; blank when there is no such line. The AI never picks a good itself |

## Seeding a Payment from 2+ receipts

Only receipts the AI recognised count. An unrecognised entry is dropped with a
warning ("1 document on the page could not be read as a receipt"). If none is
recognised, today's "Not recognised" result applies (summary → `descriptions`).

| Field | Seed |
|---|---|
| `contact_*` (payee) | not seeded |
| `payment_date` | latest receipt date (nil when no receipt has a date) |
| `funds_amount` | sum of the receipt totals |
| `descriptions` | `"<n> receipts: <shop>, <shop>, …"` with distinct shop names in read order, cut to 200 chars |
| funds account | **Cash In Hand** when every receipt's payment method is cash and that account exists; else blank (no payee → no sole-account lookup) |
| `payment_details` | one line per receipt: `descriptions` = `"<Kind> · <shop> #<doc_no> <DD/MM/YYYY>"` (the kind and parts that were not read are left out), `quantity` 1, `unit_price` = the receipt total, `discount` 0. Good, account and tax code learnt per kind (below), else blank |

A receipt with no total gets a line with amount 0 and a warning naming the shop,
so it is visible on the form rather than lost.

### Kinds and learnt goods

The kind labels are fixed English words (`Fuel`, `Toll`, `Parking`, `Hotel`,
`Meal`, `Transport`, `Other`), never translated: the label in the line text is
the key the learning looks up, so a Chinese-locale clerk must write the same
prefix. A Touch 'n Go / toll statement listing many trips is one Toll receipt.

For each kind in the read except Other: the most recent `payment_details` row
in the company (latest `payment_date`, then latest insert) whose `descriptions`
starts with `"<Kind> · "` and whose `good_id` is set. Its good is applied the
way seeded goods are (`DocPrefill`, purchase side, with the good's default
package so the line is complete), then that row's account and tax code
(with the tax code's current rate) replace the good's defaults, so an account
the clerk overrode carries forward. One lookup per kind per read.

Risk accepted: a line booked to the wrong good is copied into the next claim
until someone corrects it. Lines are only seeded into a blank form and the
clerk sees every line before Save.

`Prefill` returns `learn: nil`, `contact_ids: {nil, nil}` and `duplicate: nil`
for a multi-receipt read. TIN learning and the header duplicate check both
need a payee read from the receipt, so they don't apply here. The form's
`recheck_duplicate/3` keeps running on validate as today. It checks the
clerk-chosen payee/date/amount against earlier Payments.

## Warnings

- Each receipt's own warnings (lines don't add up, future / year-old date,
  unreadable field, negative total) are prefixed with its shop:
  `"Petronas BM: Receipt lines don't add up: …"`. Its line total is still the
  printed total.
- Closed-period and has-an-e-invoice checks run per receipt, prefixed the same way.
- `"<n> receipts from <m> shops — pick the payee (e.g. the salesperson)."` on every 2+ read.
- Dates spanning more than one day: `"Receipts are dated <first> to <last> — check the pay date."` (the form may already hold a pay date, which the blank-only merge keeps)
- Per-receipt duplicate: `"Petronas BM #12345 (RM 80.00) may already be claimed on <PAY-no>."`
- Over 40: `"<n> receipts read; only the first 40 were used. Split the claim into two Payments."`
- PurInvoice with 2+ documents: `"The file shows <n> bills — only the first was used. One Purchase Invoice per bill."`

### Per-receipt duplicate rule

For a receipt with a readable `doc_no` and total: an earlier `payment_details`
row in the same company where `descriptions` contains `"#<doc_no>"` and the
line amount (`quantity × unit_price − discount`) is within 0.01 of the total.
The first match's `payment_no` is named. Receipts without a doc no are not
checked. This relies on the line text written in decision 7, so a clerk who
rewrites the line text defeats it. That is acceptable for an advisory check.

## AI contract

`Receipts.Extract` changes from one object to a list:

```json
{"documents": [ {<today's object>}, … ]}
```

The prompt gains these rules:

- Return one entry per separate bill or receipt, in reading order (page by page,
  top to bottom, left to right).
- One document can run across pages. Continued lines, "Page x of y" and a total
  on a later page mean one entry, not several.
- A page may hold several receipts; each is its own entry.
- `recognized: false` entries are allowed for things on the page that are not
  receipts. A file with no receipt at all returns a single unrecognised entry.

`Extract.run/4` returns `{:ok, [%Extracted{}], usage}`. `decode_json/1` and
`parse/2` are unchanged per entry. A new `parse_documents/2` reads
`map["documents"]` (a list) or falls back to `[map]`.

LLM options for every receipt read: `max_tokens` 32_768 and timeout 180 s,
up from 16_384 and 90 s. Forty receipts with lines, plus Gemini's thinking
tokens, need the room. `LlmClient` already defaults higher, so this only
raises the per-call options.

The 5 MB base64 limit for images is unchanged. PDFs have no new limit.

## Code shape

- `Receipts.Extract` — prompt, `parse_documents/2`, returns a list, cap at 40
  (with the warning), new token/timeout options.
- `Receipts.Prefill.build/4` takes the list:
  - `[one]` → today's `build` (unchanged clauses).
  - PurInvoice → `build` of the first recognised document plus the "only the first" warning.
  - Payment with 2+ recognised → new `build_many/3`, per the table above.
  - none recognised → today's not-recognised clause, from the first entry's summary.
- `Prefill.claimed_warning/3` — per-receipt duplicate query.
- `FullCircleWeb.ReceiptCapture.read/3` and `finished/2` — adapt to the list
  (the seed shape `%{attrs, warnings, duplicate, learn, contact_ids, total}` is unchanged,
  so the forms and `merge_params/3` do not change). `total` is the sum for 2+.
- Receipt note on save: unchanged (it keeps the file, whatever it holds).
- `Receipts.Extracted` gains `kind`; `Extract` parses it (unknown → nil).
- `DocPrefill.apply_purchase_good/4` — public wrapper over the private
  `apply_good/5` (purchase side, with packaging).
- `Prefill.learnt_goods/3` — kind → past line lookup.
- `.claude/skills/receipt-capture.md` — the list contract, the 2+ rules, kinds, the new limits.

## Testing

Stubbed AI replies (`:llm_http`), in the existing receipt test files:

- One receipt in the new list shape → same attrs as today.
- Today's single-object reply → read as one receipt.
- 3 receipts, 3 shops, 3 dates → payee blank; 3 date-sorted lines with
  `"<shop> #<no> <date>"`; `funds_amount` = sum; `payment_date` = latest;
  "pick the payee" and date-span warnings.
- 3 receipts from one shop → payee still blank.
- All cash → Cash In Hand; mixed methods → funds account blank.
- One unrecognised entry among receipts → dropped with a warning.
- Receipt without a total → 0 line plus warning.
- 41 receipts → 40 lines plus the split warning.
- 3-page single bill (one entry) on PurInvoice → today's PurInvoice attrs.
- 2 bills on PurInvoice → first used, "only the first" warning.
- Per-receipt duplicate: an existing Payment line `"Shell #777 01/10/2026"` at
  50.00 → warning naming its payment no. Different amount → no warning.
- Kinds: line text `"Fuel · Shell #1 …"`; a saved `"Fuel · …"` line with a good
  and an overridden account → the next Fuel line takes that good, account and
  tax code; a Hotel line with no history stays blank; Other is never learnt;
  the latest saved line wins.
- Payment LiveView: payee picked first, then a 3-receipt read → payee kept,
  3 lines filled.
