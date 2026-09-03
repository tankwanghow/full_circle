---
name: fukuro-closure-backfill
description: Use when working with Fukuro's Lightspeed (Vend) POS register closures, the broken Lightspeed→Xero integration, or backfilling closure invoices into Golden Husbandry's Xero — including the pre-cutover rerun for closures after #2539.
---

# Fukuro register-closure → Xero backfill

Fukuro (fukuromgs.retail.lightspeed.app, Lightspeed Retail X-Series, Core plan) posts
daily register-closure invoices into **Golden Husbandry's Xero** (same org as the GH
import). The native Lightspeed→Xero integration died on **30 Jan 2026** (its settings
page at `/accounting/xero` errors server-side; nothing to reconnect). Closures
**#2344–#2539** plus stray **#2095** were backfilled on 2026-08-31 via
`scripts/fukuro_closure_backfill.py` as **INV-2350..INV-2546** (RM 61,943.64,
375 payments), verified against Xero.

## Data access (no API plan needed)

Core plan has no token API, but the logged-in web session can use the app's own
endpoints (via Claude-in-Chrome `javascript_tool` fetch):

- Closure list: `/register/closures?page=N&_route=register_closures` (50/page,
  newest first). Unsent rows contain "Send to Xero"; sent rows "View on Xero"
  (href carries the Xero invoice id).
- Closure summary (server-rendered HTML tables): `/register/closure/summary/<uuid>`
  — sales section, payments expected/counted/difference, uuid from the list row's
  Time-Opened link.
- Cash movements (floats): `GET /api/2.0/register_open_sequences/<uuid>/cash_movements`
  (JSON; same session cookie).
- The extension blocks tool output containing URLs-with-querystrings and uuid-heavy
  JSON ("Cookie/query string data") and caps output ~1KB/call — return compact
  semicolon lines / readable text, in chunks. `window.*` state dies on navigation
  and on extension reconnect (fresh tab group): keep harvest + export in the same
  tab without navigating.

## Document contract (replicate exactly — from historical INV-0001..2349)

ACCREC, `LineAmountTypes: Inclusive`, contact **Fukuro - Main Register**
(`3ab66d2f-0ee5-4e1e-992a-9e100a5fdf39`), Date = DueDate = closure date,
`Reference` = closure sequence #, `InvoiceNumber` = INV-<n> continuing the sequence,
Status AUTHORISED, all lines TaxType NONE:

- "Sales Account Code: 200" = New sales → **200**
- "Closing float" −250 / "Opening float" +250 → **10005** (zero-sales closures post
  float-only invoices; Xero auto-marks zero AUTHORISED invoices PAID)
- Till shortfall → "Shortfall Cash" (negative) → **431**
- Rounding: Lightspeed's Cash Rounding counted **R > 0 = till lost** (round-down) →
  post as a *payment* of +R to **411**; **R < 0 = till gained** → post a *positive*
  "Rounding Errors/Discrepancies" line of |R| to **411**. Payments are never negative.
- Payments (Date = closure date, Reference = payment-type name): Cash → **10004**,
  Touch N Go → **TNG**, Online Transfer / Debit / Visa / Master → **PBBCURR**.
- Invariant: Σ lines == Σ payments exactly per closure; Lightspeed guarantees
  Σ counted payment types (incl. rounding) == New sales.

## Script workflow

```
python3 scripts/fukuro_closure_backfill.py auth     # browser consent (write scopes)
python3 scripts/fukuro_closure_backfill.py dry-run  # plan + dupe check vs Xero
python3 scripts/fukuro_closure_backfill.py post     # typed 'post' confirm; user runs it
python3 scripts/fukuro_closure_backfill.py verify   # re-read Xero, reconcile
```

- Data in `priv/xero_import/fukuro_backfill/` (gitignored): `closures_regular.csv`
  (`seq;closed;sales;disc;C;T;R;O;D;V;M`) + `closures_anomalies.json`.
- Shares `priv/xero_import/.credentials` with the GH import. Write scopes are the
  **granular** `accounting.invoices` + `accounting.payments` (broad
  `accounting.transactions` is NOT grantable to this app). Verified grantable.
- Idempotent: skips closures whose Reference already exists on the contact.
- The classifier blocks `echo post | …` — the user must run `post` themselves.

## Gotchas

- Lightspeed still shows the red "Send to Xero" badge on backfilled closures (it
  doesn't know we posted). Do NOT click those links — if Lightspeed ever fixes its
  connection, that would double-post (their send has no Reference dupe check).
- Before the GH prod cutover: re-harvest closures after #2539 and rerun the
  backfill so the final `--snapshot` includes all POS sales. After cutover the
  bridge is obsolete (sales land in Full Circle directly).
- Vend payment-type "Xero" = on-account sale (posts per-customer AR invoice) —
  zero in the whole backlog; if it ever appears nonzero, that closure needs
  different handling.
