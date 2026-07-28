# Trading Settlement — Attaching an Existing PurInvoice

**Date:** 2026-07-28
**Status:** Design approved, not implemented
**Supersedes nothing.** Extends `2026-07-23-trading-settlement-invoicing-design.md`.

## Problem

Settlement is push-only. The board's **Create PurInvoice** deep-links to
`/PurInvoice/new?trading_loads=…` (or `?trading_transport_drops=…`), and
`Settlement.create_pur_invoice_from_loads/4` sets the trading FK inside the same
`Multi` that creates the document.

Most purchase bills do not arrive that way. Supplier and transport-agent bills
come in as received LHDN e-invoices, and the clerk enters them from
`/PurInvoice/new?obj=<json>` via `EInvMetas.Prefill.build/4`, which knows nothing
about trading. The PurInvoice is created correctly, `trip_loads.pur_invoice_id`
and `trip_drops.transport_pur_invoice_id` stay `nil`, and the trip's Supplier and
Transport chips never go green.

This design adds the missing **attach** direction: linking trading lines to a
PurInvoice that already exists, or is being created outside the settlement board.

Scope is the purchase side only. The customer side needs nothing — we issue sales
invoices ourselves, so the push flow is the real workflow there.

## Decisions

| Question | Decision |
|---|---|
| Which screen owns the action | The PurInvoice form |
| New vs edit | Both, whenever a contact is resolved |
| Automation | Filtered candidate list, clerk ticks. No scoring, no pre-ticking |
| Dual-role contacts | Two sections, each hidden when its query is empty |
| Granularity | Document-level, as today. No line-to-line mapping |
| Quantity variance | Displayed, never blocking |
| Link timing | On save, inside the `Multi` |
| Nothing ticked | Non-blocking `:warn` flash |

## 1. Two new attach primitives

`Settlement.link_drops_to_invoice/4` already exists — the customer-side attach
primitive, written but never wired to a screen. It is the template for its two
purchase-side twins:

```elixir
link_loads_to_pur_invoice(load_ids, pur_invoice, company, user)
  # → trip_loads.pur_invoice_id

link_transport_drops_to_pur_invoice(drop_ids, pur_invoice, company, user)
  # → trip_drops.transport_pur_invoice_id
```

Each follows the existing one step for step:

1. Authorize `:create_pur_invoice`.
2. Assert `pur_invoice.company_id == company.id`.
3. Reload through the existing private `load_eligible_loads/2` /
   `load_eligible_transport_drops/2`. These already enforce
   `trip.status == "completed"`, `actual` present, FK still `nil`, and — critically
   — `trip.company_id == company.id`. Client-supplied ids never escape the company.
4. Assert a single party across the set.
5. Assert that party equals `pur_invoice.contact_id`.
6. `update_all` guarded by `is_nil(...)`, with a count check →
   `{:error, :loads_already_billed}` / `{:error, :transport_already_billed}`.

Two helpers to add beside the existing `customer_matches_invoice?/2`:
`supplier_matches_pur_invoice?/2` and `agent_matches_pur_invoice?/2`.

All three link functions are re-exported through `FullCircle.Trading`, matching
how `link_drops_to_invoice/4` is already wrapped there.

No migration. No schema change. The FK columns and every existing guard
(`pur_invoice_settlement_info/2`, the contact lock, `unlink_pur_invoice_settlement/3`,
the `:has_invoices` block on trip cancel) keep working untouched.

## 2. Candidate query — nothing new

`Settlement.list_unbilled_loads/3` and `list_unbilled_transport_lines/3` already
accept `:supplier_id` / `:agent_id` and a date range, already exclude billed rows
when `:trip_id` is absent, and already return a per-row `billable` boolean.

The panel calls both with the resolved `contact_id`:

- A contact who is both grain supplier and haulier gets both sections. A section
  whose query returns `[]` is not rendered.
- Default window: `pur_invoice_date - 45 days` to `pur_invoice_date + 7 days`,
  recomputed when the clerk edits the bill date. Monthly billing cycles fit; late
  bills do not.
- **Show all unbilled** toggle drops the date bounds entirely, for the long tail.
- Non-billable rows (trip still `draft` / `planned`) render greyed and untickable
  rather than being hidden. A clerk hunting for an expected line otherwise has no
  way to tell why it is absent.
- The panel is hidden while `contact_id` is `nil`. Name-matched e-invoice contacts
  still resolve to a contact, so the panel works on that path.

## 3. UI

A `LiveComponent` at `lib/full_circle_web/live/pur_invoice_live/trading_attach_component.ex`.
Not more code in `form.ex`, which is already ~1300 lines.

The component owns both queries, the window toggle and the tick state, and
notifies the parent. The parent holds `:trading_link_load_ids` and
`:trading_link_transport_drop_ids`.

Placement: a collapsible panel between the e-invoice preview and the detail lines.

Columns per row: trip date, TRP reference, vehicle, good, route or location,
`actual` quantity, supply title.

Section footer shows quantity variance, advisory only:

```
Linked: 3 lines · 84.220 Mt      Bill qty: 84.500      Δ 0.280
```

Coloured like the existing `Prefill.variance/2` strip. It never blocks and never
gates the save. On a multi-good bill the comparison is a crude sum across units —
it is a smell detector, not a reconciliation, and the code should say so.

Must read correctly in both light and dark themes.

## 4. Save path

A new branch in `handle_event("save", …)`, beside the existing `trading_loads` /
`trading_transport_drops` push branches:

- **Create** — `Billing.create_pur_invoice_multi/4`, then the link steps.
- **Edit** — `do_update_pur_invoice/5` switches from `Billing.update_pur_invoice/4`
  to `update_pur_invoice_multi/5`, then the same link steps.

One shared helper appends them for both, so linking lives in a single place rather
than three near-copies:

```elixir
Settlement.attach_links_multi(multi, load_ids, transport_drop_ids, company, user)
```

It appends `Multi.run(:link_trading_loads, …)` and
`Multi.run(:link_trading_transport, …)`, skipping either when its id list is empty.
The link functions do not open their own transaction, so they compose inside the
caller's `Multi`.

On a lost race the whole `Multi` rolls back. This matches the push flow's existing
behaviour and is tolerable because LiveView retains the submitted form params on a
failed save — the clerk unticks the stolen line and re-saves, they do not re-key
the bill.

On success, re-read `pur_invoice_settlement_info/2` so the existing "Linked to
trading settlement" banner, the contact lock on the supplier field, and the desk
chips all reflect the new state immediately.

Unlink already exists and needs no work.

### Error mapping

| Error | Flash |
|---|---|
| `:loads_already_billed` / `:transport_already_billed` | `:warn` — another user billed these lines; panel refreshes |
| `:mixed_suppliers` / `:mixed_agents` | `:error` — one supplier per bill |
| `:supplier_mismatch` / `:agent_mismatch` | `:error` — lines belong to a different party than the bill |
| `:ineligible_loads` / `:ineligible_transport` | `:error` — trip no longer completed, or line already billed |

## 5. The miss guard

After a successful **create** with zero links, if the contact still has at least
one `billable` row in either candidate query, flash:

> 3 trading lines for this supplier are still unbilled.

The save succeeds regardless. This fires only on create, and only when billable
rows exist in the default window — plenty of purchases from a grain supplier are
genuinely not trading (bags, fuel, repairs), and a nudge on every one of those
becomes noise.

The flash kind is `:warn`. Not `:warning`, which renders nothing at all, silently.

## 6. Testing

**Context** (`test/full_circle/trading/`):

- Both link functions, happy path, FK set.
- Mixed suppliers / mixed agents rejected.
- Party mismatch against `pur_invoice.contact_id` rejected.
- Already-billed race: second call returns `:loads_already_billed` and changes
  nothing.
- Cross-company load id fails. The loaders scope on `company_id`; pin it so a
  future "tidier" refactor cannot drop the scope.

**LiveView:**

- E-invoice-seeded new PurInvoice renders the panel for a resolved contact; tick,
  save, FK is set and `trip_settlement_badges/1` reports the supplier stream done.
- Edit an existing unlinked PurInvoice, attach, save, same result.
- Save with nothing ticked while billable rows exist produces the `:warn` flash.
- Panel is absent when the contact has no unbilled trading lines.

**Regression:** the existing push-flow tests must pass untouched.

## Non-goals

- **Scoring or pre-ticking candidates.** Revisit only with the kind of backtest the
  `Prefill` good-selection rules got — a wrong link changes no amount and nothing
  downstream would catch it, the same trap documented in `e-invoice-bill-prefill.md`.
- **Line-to-line mapping** between `pur_invoice_details` and trip lines. The
  e-invoice line count rarely matches the trip line count anyway.
- **The customer / sales side.** We issue those documents, so push works.
- **Amount or price variance.** Quantity only.
