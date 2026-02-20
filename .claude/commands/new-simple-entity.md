Create a new simple CRUD entity (like Account, TaxCode): $ARGUMENTS

Provide the entity name, context, table name, and fields.

## Steps

### 1. Create Database Migration
```bash
mise exec -- mix ecto.gen.migration create_<table_name>
```

Migration should:
- Use `binary_id` primary key
- Add `company_id` as `references(:companies, type: :binary_id)`
- Add `timestamps(type: :utc_datetime)`
- Create unique index on `[:name, :company_id]` (or appropriate uniqueness constraint)

### 2. Create Schema
Location: `lib/full_circle/<context>/<entity>.ex`

```elixir
defmodule FullCircle.<Context>.<Entity> do
  use FullCircle.Schema
  import Ecto.Changeset
  import FullCircle.Helpers

  schema "<table_name>" do
    field :name, :string
    # ... other fields ...
    belongs_to :company, FullCircle.Sys.Company
    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(entity, attrs) do
    entity
    |> cast(attrs, [:name, :company_id, ...])
    |> validate_required([:name])
    |> unsafe_validate_unique([:name, :company_id], FullCircle.Repo, message: "has already been taken")
    |> unique_constraint(:name, name: :<table_name>_unique_index_name)
  end
end
```

### 3. Add to Context Module
If the context already exists, add a query function:

```elixir
# In the existing context module, or StdInterface handles it automatically
# StdInterface.filter/6 requires the schema to participate in company-scoped queries
```

StdInterface handles CRUD automatically. The schema just needs a `changeset/2` function.

### 4. Add Authorization
In `lib/full_circle/authorization.ex`:
```elixir
def can?(user, :create_<entity>, company),
  do: allow_roles(~w(admin manager supervisor), company, user)
def can?(user, :update_<entity>, company),
  do: allow_roles(~w(admin manager supervisor), company, user)
def can?(user, :delete_<entity>, company),
  do: allow_roles(~w(admin manager supervisor), company, user)
```

### 5. Create LiveView Files

**Index** (`lib/full_circle_web/live/<entity>_live/index.ex`):
- Search with fuzzy matching via `StdInterface.filter/6`
- Streaming for infinite scroll
- Fields to search: typically `[:name, :descriptions]`

**Form** (`lib/full_circle_web/live/<entity>_live/form.ex`):
- Mount new vs edit
- Validate on change
- Save via `StdInterface.create/5` or `StdInterface.update/6`

**IndexComponent** (`lib/full_circle_web/live/<entity>_live/index_component.ex`):
- Table row component with key display fields
- Edit link

### 6. Add Routes
In `router.ex` under `:require_authenticated_user_n_active_company`:
```elixir
live("/<entities>", <Entity>Live.Index, :index)
live("/<entities>/new", <Entity>Live.Form, :new)
live("/<entities>/:id/edit", <Entity>Live.Form, :edit)
```

### 7. Create Fixture
Location: `test/support/fixtures/<context>_fixtures.ex`

```elixir
def <entity>_fixture(attrs \\ %{}, user, company) do
  {:ok, entity} =
    StdInterface.create(<Entity>, "<entity>",
      Map.merge(%{name: "test_#{System.unique_integer()}"}, attrs),
      company, user)
  entity
end
```

### 8. Create Tests
Location: `test/full_circle/<context>_test.exs` and `test/full_circle_web/live/<entity>_live_test.exs`

### 9. Run
```bash
mise exec -- mix ecto.migrate
mise exec -- mix test test/full_circle/<context>_test.exs
```

## Reference Files
- Account pattern: `lib/full_circle/accounting/account.ex`
- Account LiveView: `lib/full_circle_web/live/account_live/`
- Account test: `test/full_circle_web/live/account_live_test.exs`
