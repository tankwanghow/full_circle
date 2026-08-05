# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Skill Authoring Convention

When, during a session, you discover **reusable domain knowledge** that isn't yet captured
in a `.claude/skills/*.md` file — a non-obvious pattern, gotcha, workflow, schema/API contract,
or convention that future sessions would benefit from — proactively **draft a new skill** (or
extend the closest existing one) and **ask the user to confirm** before finalizing. Do not
auto-create silently and do not skip the confirmation.

- Skills live in `.claude/skills/` (project) or `~/.claude/skills/` (broadly reusable). Each is
  one markdown file with frontmatter (`name`, `description`); the `description` is the trigger
  text, so make it specific about *when* the skill applies.
- Prefer **extending an existing skill** over creating a near-duplicate.
- Use the `superpowers:writing-skills` skill for structure/verification when authoring.
- Keep skills in sync with the code they describe; flag drift when you notice it.

## Project Overview

Full Circle is a multi-tenant web-based ERP system built with Elixir/Phoenix, covering accounting, billing, payroll (Malaysia-standard), inventory, and agricultural operations. It uses Phoenix LiveView exclusively for the UI (no REST/SPA pattern).

**Runtime versions:** Elixir 1.19.5, Erlang/OTP 28.3.1, Phoenix 1.8.3, Phoenix LiveView 1.1.x

## Git

Remote origin uses SSH: `git@github.com:tankwanghow/full_circle.git`

## Common Commands

```bash
# Setup
mix setup                        # deps.get, ecto.setup, assets.setup, assets.build

# Development
mix phx.server                   # Start dev server (HTTP :4000, HTTPS :4001)
iex -S mix phx.server            # Start with interactive shell

# Database
mix ecto.migrate                 # Run migrations
mix ecto.reset                   # Drop, create, migrate, seed

# Testing
mix test                         # Run all tests (auto-creates/migrates test DB)
mix test test/full_circle/accounting_test.exs          # Single test file
mix test test/full_circle/accounting_test.exs:42       # Single test at line

# Code quality
mix credo                        # Static analysis

# Assets
mix assets.build                 # Build CSS (Tailwind) and JS (esbuild)
mix assets.deploy                # Minified build + phx.digest for production
```

### Shared workspace assets & Docker deploy

Asset binaries live in `~/Projects/elixir/.global_assets` (see
`~/Projects/elixir/shared_config/WORKSPACE_ASSETS.md`). Run `.global_assets/setup.sh` once.

Linode deploy uses the monorepo root as Docker build context:

```bash
./deploy_to_linode/deploy.sh deploy.conf
```

See also `deploy_skills.md` for the full deploy flow.

### Ops scripts

```bash
# Restore a prod pg_dump -Ft into local full_circle_dev (drop/recreate — safer than pg_restore -c)
./scripts/restore_backup.sh backup_at_YYYYMMDDHHMMSS.tar
```

### Tutorial screencasts

`screencasts/` generates the staff tutorial videos in `docs/screencasts/` by
driving the dev server with Playwright. See `screencasts/README.md`.

```bash
cd screencasts && node record.mjs --doctor   # verify deps, creds, server
cd screencasts && node record.mjs --all --dry # selector smoke check after UI changes
```

Run the dry check after changing Billing LiveViews — it fails on any selector a
lesson can no longer find. MP4s are gitignored; recordings contain
production-derived data and must stay internal.

## Architecture

### Multi-Tenancy

Every entity belongs to a `Company`. Routes are scoped as `/companies/:company_id/*`. The `set_active_company` plug verifies user access via `CompanyUser` junction table and stores the active company in session. All queries are scoped through `Sys.user_company(company, user)` subquery joins to enforce data isolation.

### Two Ecto Repos

- **`FullCircle.Repo`** — Primary read/write repo
- **`FullCircle.QueryRepo`** — Read-only repo (separate DB user `full_circle_query`) for complex reporting queries

### Custom Schema Base

`FullCircle.Schema` (`lib/schema.ex`) sets `binary_id` as primary key type for all schemas. Use `use FullCircle.Schema` instead of `use Ecto.Schema`.

### Domain Contexts (`lib/full_circle/`)

| Context | Purpose |
|---------|---------|
| `Accounting` | GL accounts, transactions, tax codes, fixed assets, contacts |
| `Billing` | Sales invoices (`Invoice`) and purchase invoices (`PurInvoice`) |
| `ReceiveFund` | Cash receipts, received cheques |
| `BillPay` | Payments |
| `Cheque` | Deposits, returns, post-dated cheques |
| `DebCre` | Debit/credit notes |
| `HR` | Employees, salary types, pay slips, time attendance, holidays |
| `Product` | Goods and packaging (Order/Load/Delivery removed — grain uses Trading) |
| `Layer` | Agricultural: houses, flocks, harvests, weighing, movements |
| `EggStock` | Daily egg stock board, weekly DOW books, hybrid forecast |
| `Trading` | Grain trading desk: supply/sales positions, locations, multi-good trips |
| `BankReconciliation` | Bank statement import/match (LLM parser skill) |
| `EInvMetas` | E-invoice metadata (Malaysia LHDN integration) |
| `Reporting` | Report queries (cash forecast, CP204, etc.) |
| `StatutoryConfig` / `PayScript` / `Tax` | Malaysia statutory rates, pay scripts, tax helpers |
| `Sys` | Companies, users, logging |
| `UserAccounts` | Authentication (bcrypt, session tokens) |
| `Authorization` | Role-based access via `can?(user, :action, company)` |

Project skills (non-obvious domain contracts) live in `.claude/skills/`:
`grain-trading-desk.md`, `egg-stock-day-board.md`, `e-invoice-sync.md`,
`e-invoice-bill-prefill.md`, `bank-recon-llm-parser.md`, `cash-forecast-model.md`,
`cp204-instalment-planner.md`, `punch-card-payroll.md`, `finger-print-import.md`,
`statutory-bundle.md`, `liveview-computed-field-gotchas.md`.

### StdInterface Pattern (`lib/full_circle/std_interface.ex`)

Reusable CRUD operations used across most contexts: `get!`, `filter`, `create`, `save`, `delete`. Accepts schema class, company, and user — automatically handles authorization checks and audit logging. When adding a new entity, implement the `query/2` function in the schema's context.

### Authorization Roles

Defined in `lib/full_circle/authorization.ex`. Roles: `admin`, `manager`, `supervisor`, `cashier`, `clerk`, `auditor`, `punch_camera`, `guest`, `disable`. Authorization uses pattern-matched `can?/3` functions.

### LiveView Structure (`lib/full_circle_web/live/`)

Each feature follows a consistent folder pattern:
- `index.ex` — List view with search/pagination
- `form.ex` — Create/edit form
- `index_component.ex` — Table row component for index
- `detail_component.ex` — Nested detail line component (e.g., invoice lines)
- `print.ex` — Print-optimized view (uses `print_root` layout, HTML print stylesheets)

### Layouts

Five layouts in `lib/full_circle_web/components/layouts/`:
- `root.html.heex` — Main app shell
- `app.html.heex` — Authenticated app content
- `print_root.html.heex` — Print-optimized (no nav, print CSS)
- `punch.html.heex` — Time punch kiosk mode
- `recon.html.heex` — Face recognition attendance

### Frontend Assets

- **CSS**: Tailwind CSS 3.4, configured in `assets/tailwind.config.js`
- **JS**: esbuild with ESM format and code splitting. Entry points in `assets/js/`:
  - `app.js` — Main app (LiveView hooks, IndexedDB caching via `indexdb.js`)
  - `tri_autocomplete.js` — Custom autocomplete component
  - `take_photo_human.js` / `face_id.js` — Face recognition (uses Human.js library in `assets/vendor/human-main/`)
  - `qr_attend.js` — QR code attendance scanning

### I18n

Supports English (`en`) and Chinese (`zh`) via Gettext. Locale stored in session, set by `set_locale` plug.

### Key Conventions

- Document numbers are gapless per company (see `create_gapless_doc_number` migration); trading uses SUP-/SAL-/TRP- prefixes
- Transactions use a double-entry pattern with `Transaction` and `TransactionMatcher` tables
- Database triggers handle transaction posting automatically (see `create_transaction_trigger` migration)
- Print views support `pre_print` parameter (true = data only for pre-printed forms, false = full letterhead)
- Company deletion cascades via database triggers (see `create_triggers_when_delete_company` migration)
- PostgreSQL `pg_trgm` extension used for fuzzy search (see `create_fuzzy_search` migration)
- Design docs / plans: `docs/superpowers/specs/` and `docs/superpowers/plans/`
- Commit on `master` directly (solo workflow — no feature branches unless asked)
