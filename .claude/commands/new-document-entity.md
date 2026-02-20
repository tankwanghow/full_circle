Create a new financial document entity: $ARGUMENTS

Provide the entity name (e.g., "CashVoucher"), the context module name, and a brief description.

## Steps

### 1. Create the Header Schema
Location: `lib/full_circle/<context>/<entity>.ex`

Follow the Invoice pattern:
- `use FullCircle.Schema`
- `belongs_to :company, FullCircle.Sys.Company`
- `belongs_to :contact, FullCircle.Accounting.Contact`
- `has_many :<entity>_details, <DetailModule>, on_replace: :delete`
- Virtual fields for computed amounts and associated names
- `changeset/2` with `cast_assoc` for details
- `admin_changeset/2` allowing doc number editing
- `compute_fields/1` (changeset-based) and `compute_struct_fields/1` (struct-based)
- `timestamps(type: :utc_datetime)`

### 2. Create the Detail Schema
Location: `lib/full_circle/<context>/<entity>_detail.ex`

Follow the InvoiceDetail pattern:
- `field :_persistent_id, :integer` for ordering
- `belongs_to` for parent, good, account, tax_code, package
- Virtual fields for computed amounts (good_amount, tax_amount, amount)
- `changeset/2` with compute_detail_fields
- Deletion support: `field :delete, :boolean, virtual: true, default: false`

### 3. Create the Context Module
Location: `lib/full_circle/<context>.ex`

Include:
- `@<entity>_txn_opts` with sign conventions
- `get_<entity>!/3` with preloads and compute_struct_fields
- `create_<entity>/3` using Ecto.Multi chain:
  1. `get_gapless_doc_id` for document numbering
  2. `Multi.insert` with `make_changeset`
  3. `Multi.insert` for audit log
  4. `create_doc_transactions` for GL entries
- `update_<entity>/4` with:
  1. `remove_field_if_new_flag` for protected fields
  2. `update_doc_multi` (update + delete old GL + create new GL)
- `<entity>_index_query` with `apply_index_filters`
- `make_changeset/5` for admin changeset selection

### 4. Add Authorization
In `lib/full_circle/authorization.ex`:
```elixir
def can?(user, :create_<entity>, company),
  do: allow_roles(~w(admin manager supervisor clerk cashier), company, user)
def can?(user, :update_<entity>, company),
  do: allow_roles(~w(admin manager supervisor clerk cashier), company, user)
```

### 5. Add GaplessDocId Migration
Create migration to add document type to gapless_doc_ids table.

### 6. Create LiveView Files
- `lib/full_circle_web/live/<entity>_live/index.ex`
- `lib/full_circle_web/live/<entity>_live/form.ex`
- `lib/full_circle_web/live/<entity>_live/index_component.ex`
- `lib/full_circle_web/live/<entity>_live/detail_component.ex`
- `lib/full_circle_web/live/<entity>_live/print.ex`

### 7. Add Routes
In `router.ex` under `:require_authenticated_user_n_active_company`:
```elixir
live("/<EntityRoute>", <Entity>Live.Index, :index)
live("/<EntityRoute>/new", <Entity>Live.Form, :new)
live("/<EntityRoute>/:id/edit", <Entity>Live.Form, :edit)
```

Under print layout:
```elixir
live("/<EntityRoute>/:id/print", <Entity>Live.Print, :print)
live("/<EntityRoute>/print_multi", <Entity>Live.Print, :print)
```

### 8. Create Test Fixture
Location: `test/support/fixtures/<context>_fixtures.ex`

### 9. Create Tests
- `test/full_circle/<context>_test.exs` - Context tests
- `test/full_circle_web/live/<entity>_live_test.exs` - LiveView tests

### 10. Run Tests
```bash
mise exec -- mix test test/full_circle/<context>_test.exs
```

## Reference Files
- Invoice pattern: `lib/full_circle/billing.ex`, `lib/full_circle/billing/invoice.ex`
- Receipt pattern: `lib/full_circle/receive_fund.ex`, `lib/full_circle/receive_funds/receipt.ex`
- Test pattern: `test/full_circle/billing_test.exs`
- Fixture pattern: `test/support/fixtures/billing_fixtures.ex`
