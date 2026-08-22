# Xero Import (one-time tool)

This module replayed the **Golden Husbandry** Xero organisation into Full Circle as
live documents. It is a **one-time migration tool** — dev rehearsals ran in August
2026; the production run happens once. It is kept in the tree because its tests
encode hard-won accounting rules and some of its groundwork is shared
infrastructure.

The full as-built contract lives in **`.claude/skills/xero-import.md`** — read that
before changing anything here. This file is the short human survival guide.

## Danger

`mix full_circle.import_xero --apply --reset --yes` **deletes the named company and
all of its data** before re-importing. After the production cutover there is no
reason to ever run `--reset` against production. The OAuth credentials at
`priv/xero_import/.credentials` should be deleted (and the app revoked in Xero)
once the final run is done.

## Things that look wrong but are intentional

- **`__xero_line__` good** — the catch-all good on every imported detail line whose
  Xero line had no item. It is load-bearing: renaming or deleting it breaks
  thousands of historical documents.
- **"Net Profit for The Year" account (Revenue-typed)** — the contra used by
  `XCLOSE-*` year-end closing journals (KPST convention). The P&L type is what
  makes closed years self-cancel in aggregate while keeping account history.
- **Payments funded from liability accounts** — a few imported payments are funded
  from "Director Fund Payable" (that is how Xero recorded them). The import path
  has no funds-account type restriction; only the UI autocomplete limits new
  entry to Bank/Cash. Do not "harden" the schema validation to Bank/Cash — it
  would make these historical documents uneditable.
- **Synthetic `e_inv_internal_id`s** — imported bills carry placeholder ids (e.g.
  `PR-0058-PERTUBUHAN`), not real LHDN submissions. E-invoice sync logic must not
  treat them as submitted documents.
- **`package_qty` mirrors `quantity`** on imported detail lines — the edit form
  recomputes quantity as `package_qty × unit_multiplier`, so both must be set.

## Document number glossary (in the imported company)

| Prefix | Meaning |
|--------|---------|
| `PR-*` | Reconstructed pay-run bills (per pay run, per statutory body) |
| `XWSLIP-*` | Payslip accrual journals (one per pay run) |
| `XWPAY-*` / `XWOUT-*` | Reconstructed statutory / employee wage payments |
| `XDEP-*` | Per-period depreciation journals rebuilt from asset history |
| `XCATCHUP-*` | Trial-balance safety-net journals (now rounding cents only) |
| `XCATCHUP-AGED` | Contact attribution of residual AR/AP catch-up |
| `XCLOSE-*` | Year-end closings (KPST convention, see above) |
| `XADJ-*` | Xero bank-reconciliation cent adjustments |

Pay runs, depreciation and adjustments were rebuilt from a Xero UI
"Account Transactions" report export via `scripts/xero_wage_reconstruct.py`
(→ `extra_docs.json`, merged by `Snapshot.read`), because Xero's Journals API
scope is not grantable to this app.

## Traps for a second organisation

- `extra_docs.json` and `overrides.json` are found at `priv/xero_import/` (one
  level above the snapshot dir) so they survive `--snapshot` re-pulls — which
  means the **GH-specific** files there would silently apply to any other org's
  import. Archive/remove them before importing a different organisation.

## Shared infrastructure — do not delete with this module

- The company-delete cascade migration (`delete_non_cascadeable_records`,
  migration `20260820090000`) is used by every company deletion.
- `Accounting.depreciation_dates/2`'s zero-rate guard is general-purpose.
- Tests under `test/full_circle/xero_import/` lock general accounting semantics
  (zero-total ACCREC sign rule, `package_qty` = quantity, matcher signs) — keep
  them even if the import is retired.
