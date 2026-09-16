---
name: pl-forecast-model
description: Use when working on FullCircle.Reporting.ProfitLossForecast, the Profit & Loss Forecast LiveView/print, its account-exclusion list, the per-category trailing windows, the estimated-tax rows — or when writing ANY function that persists a key into a Company's `settings` map.
---

# P&L Forecast Model

Accrual P&L forecast in `lib/full_circle/reporting/profit_loss_forecast.ex`,
LiveView at `report_live/profit_loss_forecast.ex` (+ `_print`). Elapsed periods
show real posted P&L; future periods project each category from its own
trailing-window run-rate. Sibling of the `cash-forecast-model` skill — same
"actuals-to-date + run-rate" shape, but the exclusion semantics differ (below),
so do not assume one behaves like the other.

All three settings live in one modal behind the **Settings** button next to
Query: run-rate trailing days, estimated tax rate, and the exclusion list. Do not
name that button after one section (it was "Trailing", which hid the exclusion
list well enough that users could not find it).

## The profit line is BEFORE tax

`:net_profit` is labelled **"Profit Before Tax"**. `Estimated Tax` and
`Net Profit After Tax` are separate rows below it, rendered only when
`tax_rate > 0`. Do not rename `:net_profit` back to "Net Profit" — the label was
changed deliberately, and tests assert on it.

## Exclusion applies to the WHOLE report — not just the run-rate

`pl_forecast_exclude_accounts` in company settings holds account ids that drop
out of **every** query: actuals, run-rate, prior-FY fallback, and drill-down.

This is the opposite of the cash forecast, whose exclusion list deliberately
affects **forecast periods only** ("Actual periods always show real cash"). The
two lists are separate keys on purpose and mean different things:

| | Cash Forecast | P&L Forecast |
|---|---|---|
| settings key | `cash_forecast_exclude_accounts` | `pl_forecast_exclude_accounts` |
| scope | forecast periods only | whole report, actuals included |
| unit dropped | whole **documents** touching the account | the account's own **P&L lines** |

Never merge them into one list.

### Why: the Taxation account double-count

The motivating case is a user-created `Taxation` account of type **Expenses**
holding tax paid during the year. Left in, it:

1. sits inside the `Expenses` category, so "Profit Before Tax" is understated by
   the tax already paid; then
2. `apply_tax/3` charges `Estimated Tax` **on top of** that already-taxed figure;
   and
3. `run_rate_daily_by_type` averages lumpy tax instalments into the forward
   projection as if they were recurring operating expense.

Excluding it fixes all three — which is why the exclusion has to reach the actual
columns, not just the forecast ones.

## Adding a new filtered query

All four queries join `Account` as the second binding, so they share one helper:

```elixir
defp exclude_accounts(query, []), do: query
defp exclude_accounts(query, ids), do: from([_t, a] in query, where: a.id not in ^ids)
```

The empty list short-circuits rather than going into SQL. `pl_forecast/2` reads
the list once and threads it down; `period_category_transactions/4` reads it
itself because the LiveView calls it directly for drill-down. **A new query over
P&L transactions must pipe through `exclude_accounts/2`** or the drill-down will
stop reconciling to the row it opens from.

Only P&L account types are offered in the picker (`list_pl_accounts/1`) —
excluding a balance-sheet account would do nothing here.

## GOTCHA: `company.settings` writers clobber each other

Every `save_*` helper does a read-modify-write of the whole settings map:

```elixir
settings = Map.put(com.settings || %{}, @some_key, value)
com |> Ecto.Changeset.change(settings: settings) |> Repo.update()
```

So passing the **same** `com` to two of them makes the second silently wipe the
first — it rebuilds the map from a `com.settings` that predates the first write.
It fails silently: no error, the setting just never persisted. The P&L modal
saves three keys in one submit, so it is the place this bites.

Thread the returned company through:

```elixir
{:ok, com} = PLF.save_category_trailing(com, trailing)
{:ok, com} = PLF.save_tax_rate(com, params["tax_rate"])
{:ok, com} = PLF.save_excluded_account_ids(com, ids)
com = PLF.company_with_settings(com)
```

This applies to **any** company-settings writer, not just this report. If you add
a new settings key, either thread the company or fold the write into an existing
save that already owns the map.

`company_with_settings/1` re-reads settings from the DB — needed because the
session's company struct goes stale as soon as settings are written.

## Testing

- Context: `test/full_circle/reporting/profit_loss_forecast_test.exs` —
  `ProfitLossForecastExcludeTest` covers each of the four query sites separately.
  Pass an explicit `:as_of` in exclusion/fallback tests; relying on
  `Date.utc_today()` makes prior-FY-window tests drift over time.
- LiveView: `test/full_circle_web/live/profit_loss_forecast_live_test.exs`.
  A UUID in an attribute selector must be quoted —
  `element(~s|input[phx-value-id="#{id}"]|)` — or LiveViewTest rejects the
  selector as invalid CSS.
