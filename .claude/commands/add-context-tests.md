Add comprehensive tests for the context module: $ARGUMENTS

## Instructions

1. **Identify the context**: Read the context module file in `lib/full_circle/` to understand all public functions
2. **Check existing tests**: Read the existing test file in `test/full_circle/` if it exists
3. **Check existing fixtures**: Read the existing fixture file in `test/support/fixtures/` if it exists
4. **Identify gaps**: Determine which public functions lack test coverage

## Test Categories to Cover

For each public function, create tests for:

### Authorization Tests
- Use `test_authorise_to/2` for `allow_roles` patterns
- Use `test_not_authorise_to/2` for `forbid_roles` patterns
- IMPORTANT: Use explicit list syntax `["admin", "manager"]`, NOT `~w()` sigils
- For `forbid_roles(~w(auditor guest))`, the allowed list must include `disable` and `punch_camera`

### CRUD Operations
- **Create**: Valid creation returns `{:ok, %{create_X: entity}}`, unauthorized returns `:not_authorise`
- **Read/Get**: Verify computed fields, preloaded associations, virtual field population
- **Update**: Verify entity updates, GL transaction recreation, document number preservation
- **Delete**: If applicable, verify cascade behavior

### GL Transaction Tests (for financial documents)
- Verify correct number of transactions created
- Verify amounts (use `Decimal.eq?/2` for comparisons)
- Verify account assignments (control account, detail accounts, tax accounts)
- Verify sign conventions (negate_line vs negate_header)

### Index Query Tests
- Filter by search terms
- Filter by date range
- Filter by balance status (Paid/Unpaid/All)

## Pattern to Follow

```elixir
defmodule FullCircle.{Context}Test do
  use FullCircle.DataCase
  import FullCircle.{Context}Fixtures
  # Import other needed fixtures

  setup do
    # Use the context's setup function or create admin + company
    %{admin: admin, company: company}
  end

  describe "{context} authorization" do
    test_authorise_to(:create_X, ["role1", "role2", ...])
    test_authorise_to(:update_X, ["role1", "role2", ...])
  end

  describe "create_X/3" do
    test "with valid data", %{admin: admin, company: company} do
      # Setup fixtures (contact, good, account, etc.)
      # Build attrs using fixture helper
      # Assert {:ok, %{create_X: entity}} = Context.create_X(attrs, company, admin)
      # Verify entity fields
      # Verify GL transactions if applicable
    end

    test "unauthorized", %{company: company} do
      guest = user_fixture()
      # Set role to unauthorized role
      assert :not_authorise = Context.create_X(attrs, company, guest)
    end
  end
end
```

## Key Conventions
- Use `mise exec -- mix test <file>` to run the specific test file
- Use `Decimal.eq?/2` for all decimal comparisons
- Detail attrs must use map-indexed format: `%{"0" => %{...}}`
- Set `unit_multiplier: "0"` in test fixtures for simpler quantity calculations
- `funds_account_fixture/2` creates cash accounts (not seeded by default)
- Always check `authorization.ex` for the exact `can?` clause to determine test expectations
