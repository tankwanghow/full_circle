# Cash Forecast & Free Cash Flow Report — Design

**Date:** 2026-06-09
**Status:** Approved (brainstorming complete)

## Goal

Give the company a forward-looking, rolling **13-week** cash forecast built from
Account Transaction data plus known dated commitments, so it can identify the
**free cash** that is safe to lock into fixed deposits — and for how long — to
maximize bank interest income without ever risking a cash shortfall.

## Decisions (locked during brainstorming)

| Decision | Choice |
|----------|--------|
| Forecast basis | **Both** — known dated commitments (certain) overlaid on a historical run-rate baseline (estimated) |
| Horizon / bucket | **Weekly × 13** (rolling quarter) |
| Cash-need buffer | **Forward outflow cover** — buffer = projected outflow over next N weeks (N configurable, default 2) |
| FD recommendation | **Tenure ladder** — sustainable lock-up amount at ~1/2/3-month tenures |

## Liquid scope

"Cash" = accounts of type **Cash or Equivalent** + **Bank** (from
`FullCircle.Accounting.balance_sheet_account_types/0`). User can narrow the set
on the form (multi-select of liquid accounts).

**Opening balance** at the start date = Σ `transactions.amount` for the selected
liquid accounts where `doc_date <= start_date`. Reuse the balance-brought-forward
pattern from `Reporting.account_transactions/4`.

**Sign convention:** for asset accounts, inflow = positive `amount` (consistent
with how `trail_balance`/`balance_sheet` sum `amount`). To be re-verified against
live data during implementation before trusting signs.

## Two streams

Both streams are computed over 13 weekly buckets starting at `start_date`.

### Stream A — Known commitments (CERTAIN)

Each item is placed in the week containing its date.

- **IN** — in-hand received cheques, by `ReceivedCheque.due_date`
  (reuse `Reporting.post_dated_cheques` / `contact_undeposit_cheques` machinery;
  in-hand = not deposited and not returned, due_date within horizon).
- **IN** — unpaid **sales** invoice balances, by `Invoice.due_date`.
- **OUT** — unpaid **purchase** invoice balances, by `PurInvoice.due_date`.
- **IN/OUT** — already-posted future-dated liquid-account transactions
  (`doc_date > start_date`), by their `doc_date`.

**Open invoice balance** = invoice amount − matched receipts/payments via
`TransactionMatcher` (same outstanding-balance logic the aging report uses).
Only invoices with a positive remaining balance and `due_date` within the
horizon contribute. Invoices past due (due_date < start_date) but still unpaid
are placed in **week 1** (assumed collectible/payable immediately).

### Stream B — Run-rate baseline (ESTIMATED)

From the trailing **52 weeks** of liquid-account transactions (trailing window
configurable), compute average weekly inflow and outflow — restricted to
transactions with **`contact_id IS NULL`**. Rationale: every customer/supplier
(contact-bearing) cash movement is already modeled by Stream A's AR/AP and cheque
streams, so excluding them avoids double-counting; what remains is recurring
operational flow (payroll, utilities, bank charges, owner draws). Apply
`baseline_in` / `baseline_out` evenly to each of the 13 weeks.

**Known limitation:** if cash sales are recorded against a contact, they are
treated as immediately-settled AR (net ~0 outstanding) and thus appear in neither
stream — understating future inflow. This is conservative (won't over-lock FDs)
and acceptable for v1.

## Weekly roll-forward

```
opening[1]   = opening cash
opening[w]   = closing[w-1]
total_in[w]  = known_in[w]  + baseline_in
total_out[w] = known_out[w] + baseline_out
closing[w]   = opening[w] + total_in[w] - total_out[w]
buffer[w]    = Σ total_out over weeks w+1 .. w+N        (N default 2)
free_cash[w] = max(0, closing[w] - buffer[w])
```

## FD tenure ladder

```
lockable_1mo = min(free_cash, weeks 1-4)
lockable_2mo = min(free_cash, weeks 1-8)
lockable_3mo = min(free_cash, weeks 1-13)

ladder:
  3mo  = lockable_3mo
  2mo  = lockable_2mo - lockable_3mo     (>= 0)
  1mo  = lockable_1mo - lockable_2mo     (>= 0)
  on-call = remainder
```

Taking the rolling minimum guarantees no week dips below its buffer while locking
the largest amount at the longest tenure. Tenure week-boundaries (4/8/13) are
constants; can be surfaced as config later (YAGNI for v1).

## Delivery

- **Context query:** `FullCircle.Reporting.cash_forecast/…` using `QueryRepo`
  (read-only reporting repo). Returns a struct: per-week rows + ladder summary +
  meta (opening, baseline figures, assumptions).
- **LiveView:** `FullCircleWeb.ReportLive.CashForecast` under
  `lib/full_circle_web/live/report_live/`, following the `new-report` scaffold
  and the existing report LiveViews (e.g. `post_dated_cheques.ex`).
- **Form inputs:** start date (default today), buffer weeks N (default 2),
  trailing window weeks (default 52), liquid-account selection (default all
  Cash/Bank).
- **Results UI:**
  - Per-week table: opening / known-in / baseline-in / known-out / baseline-out
    / closing / buffer / free-cash. Certain vs estimated columns visually
    distinct (e.g. solid vs muted).
  - Ladder summary box (1/2/3-month lockable + suggested placement).
  - Line chart: closing balance vs buffer line across 13 weeks.
  - Print view (`print_root` layout) for the table + ladder.
- **Theming:** must look correct in both light and dark themes.
- **Route:** add under the company-scoped report routes, mirroring existing
  report routes.

## Out of scope (v1)

- Actual interest-rate math / RM-interest projection (report stops at "lockable
  amount per tenure"; user applies their bank's rates).
- Multi-currency.
- Persisting/saving forecast snapshots.
- Editable manual adjustments to projected lines.

## Testing

- Context tests for `cash_forecast/…`: opening balance, week bucketing of known
  commitments, baseline exclusion (no double-count), roll-forward arithmetic,
  buffer = forward outflow cover, ladder rolling-minimum and non-negative
  increments, edge cases (no data, all cash, negative free cash → 0).
- LiveView test: form renders, runs with params, shows weeks + ladder.
