# Full Circle ERP - Agent Development Guide

This guide provides comprehensive patterns and conventions for AI agents working on the Full Circle ERP codebase. It supplements `CLAUDE.md` with detailed implementation patterns and architectural knowledge.

## Table of Contents

- [Quick Reference](#quick-reference)
- [Architecture Deep Dive](#architecture-deep-dive)
- [Schema Patterns](#schema-patterns)
- [Context Module Patterns](#context-module-patterns)
- [LiveView Patterns](#liveview-patterns)
- [Testing Patterns](#testing-patterns)
- [Authorization Patterns](#authorization-patterns)
- [Common Tasks](#common-tasks)
- [Gotchas and Pitfalls](#gotchas-and-pitfalls)

---

## Quick Reference

### Runtime
```
Elixir 1.19.5, OTP 28.3.1, Phoenix 1.8.3, LiveView 1.1.x
Use `mise exec --` prefix for all mix/elixir commands
```

### Key File Locations
| What | Where |
|------|-------|
| Custom schema base | `lib/schema.ex` |
| StdInterface (CRUD) | `lib/full_circle/std_interface.ex` |
| Authorization | `lib/full_circle/authorization.ex` |
| Helpers | `lib/full_circle/helpers.ex` |
| Core components | `lib/full_circle_web/components/core_components.ex` |
| Layouts | `lib/full_circle_web/components/layouts/` |
| Router | `lib/full_circle_web/router.ex` |
| JS hooks | `assets/js/app.js` |
| Test support | `test/support/` |
| Fixtures | `test/support/fixtures/` |

### All Domain Contexts
| Context File | Schemas | Purpose |
|-------------|---------|---------|
| `billing.ex` | Invoice, InvoiceDetail, PurInvoice, PurInvoiceDetail | Sales & purchase invoices |
| `receive_fund.ex` | Receipt, ReceiptDetail, ReceivedCheque | Cash receipts |
| `bill_pay.ex` | Payment, PaymentDetail | Payments to suppliers |
| `debcre.ex` | CreditNote, CreditNoteDetail, DebitNote, DebitNoteDetail | Debit/credit notes |
| `cheque.ex` | Deposit, ReturnCheque | Cheque deposits & returns |
| `accounting.ex` | Account, Contact, TaxCode, Transaction, TransactionMatcher, FixedAsset, Journal | GL & master data |
| `hr.ex` | Employee, SalaryType, EmployeeSalaryType, TimeAttend, Advance, SalaryNote, PaySlip | Payroll & HR |
| `product.ex` | Good, Packaging, Delivery, Order, Load | Inventory & logistics |
| `layer.ex` | House, Flock, Harvest, HarvestDetail, Movement, HouseHarvestWage | Agriculture |
| `e_inv_metas.ex` | EInvoice, EInvMeta | Malaysia e-invoice (LHDN) |
| `reporting.ex` | *(queries only)* | Reports |
| `sys.ex` | Company, CompanyUser, Log, GaplessDocId, UserSetting | System administration |
| `user_accounts.ex` | User, UserToken | Authentication |
| `seeding.ex` | *(no schemas)* | Data import/seeding |
| `journal_entry.ex` | *(uses Journal + Transaction)* | Journal entries |
| `pay_run.ex` | *(uses PaySlip)* | Payroll batch processing |
| `tagged_bill.ex` | *(uses Invoice/PurInvoice)* | Tag-based billing queries |

### All Schema Files (61 schemas)
```
lib/full_circle/accounting/account.ex
lib/full_circle/accounting/contact.ex
lib/full_circle/accounting/fixed_asset.ex
lib/full_circle/accounting/fixed_asset_depreciation.ex
lib/full_circle/accounting/fixed_asset_disposal.ex
lib/full_circle/accounting/journal.ex
lib/full_circle/accounting/seed_transaction_matcher.ex
lib/full_circle/accounting/tax_code.ex
lib/full_circle/accounting/transaction.ex
lib/full_circle/accounting/transaction_matcher.ex
lib/full_circle/billing/invoice.ex
lib/full_circle/billing/invoice_detail.ex
lib/full_circle/billing/pur_invoice.ex
lib/full_circle/billing/pur_invoice_detail.ex
lib/full_circle/bill_pay/payment.ex
lib/full_circle/bill_pay/payment_detail.ex
lib/full_circle/cheque/deposit.ex
lib/full_circle/cheque/return_cheque.ex
lib/full_circle/debcre/credit_note.ex
lib/full_circle/debcre/credit_note_detail.ex
lib/full_circle/debcre/debit_note.ex
lib/full_circle/debcre/debit_note_detail.ex
lib/full_circle/e_inv_metas/e_inv_meta.ex
lib/full_circle/e_inv_metas/e_invoice.ex
lib/full_circle/HR/advance.ex
lib/full_circle/HR/employee.ex
lib/full_circle/HR/employee_photo.ex
lib/full_circle/HR/employee_salary_type.ex
lib/full_circle/HR/holiday.ex
lib/full_circle/HR/pay_slip.ex
lib/full_circle/HR/recurring.ex
lib/full_circle/HR/salary_note.ex
lib/full_circle/HR/salary_type.ex
lib/full_circle/HR/timeattend.ex
lib/full_circle/layer/flocks.ex
lib/full_circle/layer/harvest_details.ex
lib/full_circle/layer/harvests.ex
lib/full_circle/layer/house_harvest_wages.ex
lib/full_circle/layer/houses.ex
lib/full_circle/layer/movements.ex
lib/full_circle/product/deliver_detail.ex
lib/full_circle/product/delivery.ex
lib/full_circle/product/good.ex
lib/full_circle/product/load.ex
lib/full_circle/product/load_detail.ex
lib/full_circle/product/order.ex
lib/full_circle/product/order_detail.ex
lib/full_circle/product/packaging.ex
lib/full_circle/receive_funds/receipt.ex
lib/full_circle/receive_funds/receipt_detail.ex
lib/full_circle/receive_funds/received_cheque.ex
lib/full_circle/sys/company.ex
lib/full_circle/sys/company_user.ex
lib/full_circle/sys/gapless_doc_id.ex
lib/full_circle/sys/log.ex
lib/full_circle/sys/user_setting.ex
lib/full_circle/user_accounts/user.ex
lib/full_circle/user_accounts/user_token.ex
lib/full_circle/user_queries/query.ex
lib/full_circle/weight_bridge/weighings.ex
```

---

## Architecture Deep Dive

### Multi-Tenancy Model

Every entity belongs to a `Company`. The isolation chain:

1. **Route scope**: `/companies/:company_id/*` scopes all company-specific routes
2. **Plug**: `set_active_company` verifies user has access to company via `CompanyUser`
3. **LiveView mount**: `assign_active_company` puts `@current_company`, `@current_user`, `@current_role` into socket assigns
4. **Query isolation**: `Sys.user_company(company, user)` subquery join ensures data isolation

```elixir
# This pattern is used EVERYWHERE for query isolation
from obj in klass,
  join: com in subquery(Sys.user_company(company, user)),
  on: com.id == obj.company_id,
  select: obj
```

### Two Repos

| Repo | User | Purpose |
|------|------|---------|
| `FullCircle.Repo` | `full_circle` | Primary read/write |
| `FullCircle.QueryRepo` | `full_circle_query` | Read-only reporting (no test config, expect harmless errors) |

### Custom Schema Base

```elixir
# lib/schema.ex - ALL schemas use this instead of Ecto.Schema
defmodule FullCircle.Schema do
  defmacro __using__(_) do
    quote do
      use Ecto.Schema
      @primary_key {:id, :binary_id, autogenerate: true}
      @foreign_key_type :binary_id
    end
  end
end
```

All IDs are UUIDs (`binary_id`). Always use `use FullCircle.Schema` in new schemas.

### Gapless Document Numbering

Documents (invoices, receipts, etc.) use gapless sequential numbering per company:

```elixir
# Pattern from helpers.ex
get_gapless_doc_id(multi, name, "Invoice", "INV", com)
# Generates: INV-000001, INV-000002, etc.
```

The `GaplessDocId` table maintains a counter per document type per company. This is managed in `Ecto.Multi` chains to ensure atomicity.

### Double-Entry Bookkeeping

Every financial document creates GL `Transaction` records:

- **Invoice**: Negates detail lines (credit revenue accounts), keeps header positive (debit receivables)
- **PurInvoice**: Keeps detail lines positive (debit expense accounts), negates header (credit payables)
- **Receipt/Payment**: Creates matching transactions with `TransactionMatcher`

The `@invoice_txn_opts` / `@pur_invoice_txn_opts` pattern declares sign behavior:

```elixir
@invoice_txn_opts [
  doc_type: "Invoice",
  control_account: "Account Receivables",
  detail_key: :invoice_details,
  negate_line: true,     # Credit revenue lines
  negate_header: false   # Debit receivables header
]
```

### Transaction Matching

Payments are matched against invoices via `TransactionMatcher`:
- `SeedTransactionMatcher` — for imported/seeded historical data
- `TransactionMatcher` — for live application matches
- Balance = original amount + sum(seed matches) + sum(live matches)

---

## Schema Patterns

### Header + Detail Pattern

Most financial documents follow a header-detail pattern:

```elixir
# Header schema (e.g., Invoice)
schema "invoices" do
  field :invoice_no, :string
  field :invoice_date, :date
  belongs_to :company, FullCircle.Sys.Company
  belongs_to :contact, FullCircle.Accounting.Contact
  has_many :invoice_details, InvoiceDetail, on_replace: :delete
  # Virtual fields for computed values
  field :contact_name, :string, virtual: true
  field :invoice_amount, :decimal, virtual: true, default: Decimal.new(0)
  timestamps(type: :utc_datetime)
end

# Detail schema (e.g., InvoiceDetail)
schema "invoice_details" do
  field :_persistent_id, :integer  # For ordering
  belongs_to :invoice, Invoice
  belongs_to :good, Good
  belongs_to :account, Account
  belongs_to :tax_code, TaxCode
  # Computed virtual fields
  field :good_amount, :decimal, virtual: true, default: Decimal.new(0)
  field :tax_amount, :decimal, virtual: true, default: Decimal.new(0)
end
```

### Changeset Patterns

#### Standard Changeset
```elixir
def changeset(invoice, attrs) do
  invoice
  |> cast(attrs, [...fields...])
  |> validate_required([...required_fields...])
  |> cast_assoc(:invoice_details, with: &InvoiceDetail.changeset/2)
  |> compute_fields()
end
```

#### Admin Changeset
Allows editing fields that normal users cannot (e.g., document numbers):
```elixir
def admin_changeset(invoice, attrs) do
  invoice
  |> cast(attrs, [...fields... ++ [:invoice_no, :e_inv_internal_id]])
  |> validate_required([...])
  |> cast_assoc(:invoice_details, with: &InvoiceDetail.changeset/2)
  |> compute_fields()
end
```

### cast_assoc with Map-Indexed Attrs

Detail lines use map-indexed attributes (not lists):

```elixir
# CORRECT - map-indexed format for cast_assoc
%{
  "invoice_details" => %{
    "0" => %{"good_id" => "abc", "quantity" => "10", "unit_price" => "5.00"},
    "1" => %{"good_id" => "def", "quantity" => "20", "unit_price" => "3.00"}
  }
}
```

### Compute Fields Pattern

Most documents have `compute_fields/1` (changeset) and `compute_struct_fields/1` (loaded struct):

```elixir
def compute_fields(changeset) do
  changeset
  |> compute_detail_fields()       # Compute per-line amounts
  |> sum_field_to(:invoice_details, :good_amount, :invoice_good_amount)
  |> sum_field_to(:invoice_details, :tax_amount, :invoice_tax_amount)
  |> compute_total()
end

def compute_struct_fields(invoice) do
  invoice
  |> sum_struct_field_to(:invoice_details, :good_amount, :invoice_good_amount)
  |> sum_struct_field_to(:invoice_details, :tax_amount, :invoice_tax_amount)
  |> compute_struct_total()
end
```

---

## Context Module Patterns

### Standard CRUD via StdInterface

For simple entities (Account, Contact, TaxCode, etc.):

```elixir
# Creating
StdInterface.create(Account, "account", attrs, company, user)

# Updating
StdInterface.update(Account, "account", account, attrs, company, user)

# Deleting
StdInterface.delete(Account, "account", account, company, user)

# Querying with pagination and fuzzy search
StdInterface.filter(Account, [:name, :account_type], terms, company, user,
  page: page, per_page: per_page)

# Getting a changeset (for forms)
StdInterface.changeset(Account, %Account{}, attrs, company)
StdInterface.changeset(Account, account, attrs, company, :admin_changeset)
```

StdInterface automatically:
- Checks authorization via `can?(user, :create_account, company)`
- Creates audit logs via `Sys.insert_log_for/5`
- Scopes queries via `Sys.user_company/2`

### Document Creation via Ecto.Multi

Complex documents (invoices, receipts, etc.) use Multi chains:

```elixir
def create_invoice(attrs, com, user) do
  case can?(user, :create_invoice, com) do
    true ->
      Multi.new()
      |> get_gapless_doc_id(gapless_name, "Invoice", "INV", com)  # Step 1: Get doc number
      |> Multi.insert(:create_invoice, fn %{^gapless_name => doc} -> # Step 2: Insert document
        make_changeset(Invoice, %Invoice{},
          Map.merge(attrs, %{"invoice_no" => doc}), com, user)
      end)
      |> Multi.insert("create_invoice_log", fn %{:create_invoice => entity} ->  # Step 3: Audit log
        Sys.log_changeset(:create_invoice, entity, attrs, com, user)
      end)
      |> create_doc_transactions(:create_invoice, com, user, @invoice_txn_opts)  # Step 4: GL transactions
      |> Repo.transaction()
    false ->
      :not_authorise
  end
end
```

### Document Update Pattern

```elixir
defp update_doc_multi(multi, step_name, schema, doc, doc_no, attrs, com, user, txn_opts) do
  multi
  |> Multi.update(step_name, fn _ ->
    make_changeset(schema, doc, attrs, com, user)
  end)
  |> Multi.delete_all(:delete_transaction, ...)  # Delete old GL transactions
  |> Sys.insert_log_for(step_name, attrs, com, user)
  |> create_doc_transactions(step_name, com, user, txn_opts)  # Recreate GL transactions
end
```

### Admin Changeset Selection

```elixir
defp make_changeset(module, struct, attrs, com, user) do
  if user_role_in_company(user.id, com.id) == "admin" do
    StdInterface.changeset(module, struct, attrs, com, :admin_changeset)
  else
    StdInterface.changeset(module, struct, attrs, com)
  end
end
```

### Index Query Filter Chain

```elixir
defp apply_index_filters(qry, terms, date_from, due_date_from, bal, opts) do
  search_fields = Keyword.fetch!(opts, :search_fields)
  date_field = Keyword.fetch!(opts, :date_field)
  unpaid_op = Keyword.fetch!(opts, :unpaid_op)

  qry
  |> maybe_apply_search(terms, search_fields)
  |> maybe_apply_date_filter(date_from, date_field)
  |> maybe_apply_due_date_filter(due_date_from)
  |> maybe_apply_balance_filter(bal, unpaid_op)
end
```

### Multi.insert_all with build_* Helpers

Refactored contexts use `Multi.insert_all` with builder functions instead of `Multi.run` + `Repo.insert!`:

```elixir
multi
|> Multi.insert_all(:create_transactions, Transaction, fn %{^name => doc} ->
  build_transactions(doc, com, opts)
end)
```

---

## LiveView Patterns

### Form LiveView Structure

```elixir
defmodule FullCircleWeb.InvoiceLive.Form do
  use FullCircleWeb, :live_view

  @impl true
  def mount(params, _session, socket) do
    # Load settings, setup socket
    socket = if params["id"], do: mount_edit(socket, params), else: mount_new(socket)
    {:ok, socket}
  end

  defp mount_new(socket) do
    changeset = StdInterface.changeset(Invoice, %Invoice{}, %{}, socket.assigns.current_company)
    socket |> assign(live_action: :new) |> assign_form(changeset)
  end

  defp mount_edit(socket, %{"invoice_id" => id}) do
    obj = Billing.get_invoice!(id, socket.assigns.current_company, socket.assigns.current_user)
    changeset = StdInterface.changeset(Invoice, obj, %{}, socket.assigns.current_company)
    socket |> assign(live_action: :edit, id: id) |> assign_form(changeset)
  end

  @impl true
  def handle_event("validate", %{"invoice" => params}, socket) do
    changeset = StdInterface.changeset(Invoice, socket.assigns.obj, params, socket.assigns.current_company)
    {:noreply, assign_form(socket, changeset)}
  end

  @impl true
  def handle_event("save", %{"invoice" => params}, socket) do
    save(socket, socket.assigns.live_action, params)
  end

  defp save(socket, :new, params) do
    case Billing.create_invoice(params, socket.assigns.current_company, socket.assigns.current_user) do
      {:ok, %{create_invoice: obj}} ->
        {:noreply, socket |> push_navigate(to: ~p"/companies/#{socket.assigns.current_company.id}/Invoice/#{obj.id}/edit")}
      {:error, _, changeset, _} ->
        {:noreply, assign_form(socket, changeset)}
      :not_authorise ->
        {:noreply, put_flash(socket, :error, "Not Authorised")}
    end
  end
end
```

### Index LiveView Structure

```elixir
defmodule FullCircleWeb.InvoiceLive.Index do
  use FullCircleWeb, :live_view
  @per_page 15

  @impl true
  def handle_params(params, _url, socket) do
    # Extract search params, filter, stream results
    objects = Billing.invoice_index_query(terms, date, due_date, bal, com, user,
      page: page, per_page: @per_page)
    {:noreply, socket |> stream(:objects, objects, reset: true)}
  end

  @impl true
  def handle_event("next-page", _, socket) do
    # Increment page, append to stream
    {:noreply, socket |> stream(:objects, objects, reset: false)}
  end
end
```

### Detail Component Structure

```elixir
defmodule FullCircleWeb.InvoiceLive.DetailComponent do
  use FullCircleWeb, :live_component

  @impl true
  def render(assigns) do
    ~H"""
    <.inputs_for :let={dtl} field={@form[@detail_name]}>
      <div class={["flex flex-row", if(dtl[:delete].value == true, do: "hidden")]}>
        <.input field={dtl[:good_name]} phx-hook="tributeAutoComplete" url={...} />
        <.input type="hidden" field={dtl[:good_id]} />
        <.input field={dtl[:quantity]} phx-hook="calculatorInput" />
        <.input field={dtl[:unit_price]} phx-hook="calculatorInput" />
        <!-- ... -->
      </div>
    </.inputs_for>
    """
  end
end
```

### Print LiveView Pattern

```elixir
defmodule FullCircleWeb.InvoiceLive.Print do
  use FullCircleWeb, :live_view

  @impl true
  def mount(%{"id" => id, "pre_print" => pre_print}, _, socket) do
    # Load document data for printing
    # Calculate page breaks based on detail line count
    # Chunk details across pages
  end

  # Uses print_root layout (no nav, A4 sizing)
  # Supports pre_print mode (data only, no letterhead)
end
```

### Key JS Hooks

| Hook | Purpose | Usage |
|------|---------|-------|
| `tributeAutoComplete` | Autocomplete input | `phx-hook="tributeAutoComplete"` + `url` attribute |
| `tributeTagText` | Tag autocomplete (#tag) | `phx-hook="tributeTagText"` |
| `calculatorInput` | Math expressions in inputs | `phx-hook="calculatorInput"` |
| `clipCopy` | Copy to clipboard | `phx-hook="clipCopy"` |
| `copyAndOpen` | Copy + open URL | For e-invoice links |
| `FaceID` | Face recognition | Biometric attendance |
| `takePhoto` | Photo capture | Employee photos |
| `punchCamera` | QR scanning | QR attendance |

### Autocomplete URL Pattern

```heex
<.input
  field={@form[:contact_name]}
  phx-hook="tributeAutoComplete"
  url={"/list/companies/#{@current_company.id}/#{@current_user.id}/autocomplete?schema=contact&name="}
/>
```

Available schemas for autocomplete: `contact`, `account`, `employee`, `good`, `house`

---

## Testing Patterns

### Test Infrastructure

| Module | Purpose | Location |
|--------|---------|----------|
| `FullCircle.DataCase` | Domain context tests | `test/support/data_case.ex` |
| `FullCircleWeb.ConnCase` | LiveView & controller tests | `test/support/conn_case.ex` |

### Domain Context Test Pattern

```elixir
defmodule FullCircle.BillingTest do
  use FullCircle.DataCase
  import FullCircle.BillingFixtures
  import FullCircle.AccountingFixtures

  setup do
    %{admin: admin, company: company} = billing_setup()
    %{admin: admin, company: company}
  end

  describe "billing authorization" do
    test_authorise_to(:create_invoice,
      ["admin", "manager", "supervisor", "clerk", "cashier"])
    test_authorise_to(:update_invoice,
      ["admin", "manager", "supervisor", "clerk", "cashier"])
  end

  describe "create_invoice/3" do
    test "creates valid invoice", %{admin: admin, company: company} do
      # Setup fixtures
      good = good_fixture(admin, company)
      contact = contact_fixture(admin, company)
      attrs = invoice_attrs(good, contact, admin, company)

      # Execute
      assert {:ok, %{create_invoice: inv}} = Billing.create_invoice(attrs, company, admin)

      # Verify
      assert inv.invoice_no =~ "INV-"
      assert Decimal.eq?(inv.invoice_amount, expected_amount)
    end
  end
end
```

### Fixture Pattern

```elixir
defmodule FullCircle.BillingFixtures do
  import FullCircle.UserAccountsFixtures
  import FullCircle.SysFixtures

  def billing_setup do
    admin = user_fixture()
    company = company_fixture(admin, %{})
    %{admin: admin, company: company}
  end

  def invoice_attrs(good, contact, user, com) do
    %{
      "invoice_date" => Date.utc_today() |> Date.to_string(),
      "due_date" => Date.utc_today() |> Date.to_string(),
      "contact_name" => contact.name,
      "contact_id" => contact.id,
      "invoice_details" => %{
        "0" => %{
          "good_id" => good.id,
          "account_id" => good_account_id,
          "quantity" => "10",
          "unit_price" => "5.00",
          "unit_multiplier" => "0",  # Makes compute_fields use quantity directly
          "discount" => "0",
          "tax_rate" => "0",
          "tax_code_id" => tax_code_id,
          "package_id" => package_id
        }
      }
    }
  end
end
```

### LiveView Test Pattern

```elixir
defmodule FullCircleWeb.AccountLiveTest do
  use FullCircleWeb.ConnCase
  import Phoenix.LiveViewTest

  setup %{conn: conn} do
    user = user_fixture()
    comp = company_fixture(user, %{})
    ac = account_fixture(%{name: "TESTACCOUNT"}, user, comp)
    %{conn: log_in_user(conn, user), user: user, comp: comp, ac: ac}
  end

  describe "Edit" do
    test "save valid account", %{conn: conn, comp: comp, ac: ac} do
      {:ok, lv, _html} = live(conn, ~p"/companies/#{comp.id}/accounts/#{ac.id}/edit")
      {:ok, _, html} =
        lv
        |> form("#account", account: %{name: "new_name"})
        |> render_submit()
        |> follow_redirect(conn)
      assert html =~ "new_name"
    end
  end

  # Custom test macros
  describe "data validation" do
    test_input_feedback("account", "name", "", "can't be blank")
    test_input_feedback("account", "name", "TESTACCOUNT", "has already been taken")
  end

  describe "data value" do
    test_input_value("account", "input", :text, "name")
    test_input_value("account", "select", :text, "account_type")
  end
end
```

### Custom Test Macros

| Macro | Module | Purpose |
|-------|--------|---------|
| `test_authorise_to/2` | `DataCase` | Tests roles that ARE allowed |
| `test_not_authorise_to/2` | `DataCase` | Tests roles that are NOT allowed |
| `test_input_value/4` | `ConnCase` | Verifies form field values |
| `test_input_feedback/4` | `ConnCase` | Verifies validation error messages |

### Test Fixture Hierarchy

```
user_fixture()           -> User
  |
  company_fixture(user)  -> Company (with seeded accounts like "Account Receivables")
    |
    +-- contact_fixture(user, company)
    +-- good_fixture(user, company)     -> Good + Packaging + TaxCodes
    +-- account_fixture(attrs, user, company)
    +-- funds_account_fixture(user, company)  -> "Cash or Equivalent" account
    +-- bank_account_fixture(user, company)   -> "Bank" account
```

**Important**: Default seeded accounts do NOT include cash accounts. Use `funds_account_fixture` to create one for receipt/payment tests.

---

## Authorization Patterns

### Role Hierarchy

Roles (from `authorization.ex`): `admin`, `manager`, `supervisor`, `cashier`, `clerk`, `auditor`, `punch_camera`, `guest`, `disable`

### Two Authorization Styles

**`allow_roles`** - Whitelist: only listed roles can perform the action
```elixir
def can?(user, :create_invoice, company),
  do: allow_roles(~w(admin manager supervisor clerk cashier), company, user)
```

**`forbid_roles`** - Blacklist: all roles EXCEPT listed ones can perform the action
```elixir
def can?(user, :create_contact, company),
  do: forbid_roles(~w(auditor guest), company, user)
```

### Testing Authorization

```elixir
# For allow_roles - list the allowed roles
test_authorise_to(:create_invoice,
  ["admin", "manager", "supervisor", "clerk", "cashier"])

# For forbid_roles - list ALL roles NOT in the forbid list
# forbid_roles(~w(auditor guest)) means everyone EXCEPT auditor and guest is allowed
# So the allowed list includes disable and punch_camera too!
test_authorise_to(:create_contact,
  ["admin", "manager", "supervisor", "cashier", "clerk", "disable", "punch_camera"])
```

**CRITICAL**: When authorization uses `forbid_roles`, the `disable` and `punch_camera` roles are allowed unless explicitly forbidden. Include them in the test's allowed list.

---

## Common Tasks

### Adding a New Simple Entity (like Account, TaxCode)

1. Create schema in `lib/full_circle/<context>/<entity>.ex`
2. Add `changeset/2` and optionally `admin_changeset/2`
3. Add `can?` clauses in `authorization.ex` for `:create_<entity>`, `:update_<entity>`, `:delete_<entity>`
4. Use `StdInterface` for CRUD in the context module
5. Create LiveView files: `index.ex`, `form.ex`, `index_component.ex`
6. Add routes in `router.ex` under the company-scoped live_session
7. Create test file and fixture

### Adding a New Document Entity (like Invoice, Receipt)

1. Create header schema with `has_many` details
2. Create detail schema with `belongs_to` header
3. Add `changeset/2`, `admin_changeset/2`, `compute_fields/1`, `compute_struct_fields/1`
4. Create context module with:
   - `@txn_opts` for GL transaction configuration
   - `create_<doc>/3` with `Ecto.Multi` chain
   - `update_<doc>/4` with transaction deletion + recreation
   - `get_<doc>!/3` with preloads and `compute_struct_fields/1`
   - Index query function with `apply_index_filters/6` or `apply_simple_filters/4`
5. Add authorization `can?` clauses
6. Create LiveView: form.ex, index.ex, detail_component.ex, print.ex, index_component.ex
7. Add routes (regular + print)
8. Create test file and fixture file

### Adding a New Report

1. Add query function in `reporting.ex` or relevant context
2. Create LiveView in `lib/full_circle_web/live/report_live/`
3. Add route under company-scoped live_session
4. Optionally create print version with `print_root` layout

---

## Gotchas and Pitfalls

### Must-Know Issues

1. **`mise exec --` prefix**: All `mix`/`elixir` commands must use this prefix for correct runtime versions

2. **QueryRepo test errors**: `missing :database key` errors for `FullCircle.QueryRepo` in test output are harmless noise - QueryRepo has no test configuration

3. **`uploads_dir` in test config**: `config/test.exs` must have `uploads_dir: System.tmp_dir!()` for `Sys.create_company/2` to work

4. **`unit_multiplier: "0"`** in test fixtures: This makes `compute_fields` use quantity directly (avoids package quantity multiplication)

5. **`remove_field_if_new_flag`**: Update operations must pass `e_inv_internal_id` and `invoice_no` (or equivalent doc number fields) in attrs, otherwise they get stripped

6. **`test_authorise_to` needs explicit list**: Use `["admin", "manager"]` not `~w(admin manager)` - the macro doesn't work with sigils

7. **Dev DB has production data**: Useful for checking real account names, schema structure, and data patterns

8. **Seeded accounts**: When a company is created, certain accounts are seeded (like "Account Receivables", "Account Payables", "Sales Tax Payable", etc.) but NOT cash accounts

9. **Phoenix 1.8 requirement**: Config must include `listeners: [Phoenix.CodeReloader]`

10. **Always test-first**: Write tests BEFORE implementing behavioral changes (established project convention)

### Common Decimal Pitfalls

- Always use `Decimal.new("0")` not `0` for default values
- Use `Decimal.eq?/2` for comparisons, not `==`
- Use `Decimal.round(val, 2)` for monetary amounts
- `Decimal.negate/1` for sign reversal in bookkeeping

### Changeset Debugging

- Check `changeset.valid?` and `changeset.errors` for validation issues
- Detail changesets: check `Ecto.Changeset.get_change(changeset, :invoice_details)` for nested errors
- Use `errors_on/1` helper in tests: `assert %{name: ["can't be blank"]} = errors_on(changeset)`
