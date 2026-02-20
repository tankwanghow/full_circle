# Testing Skills

This file documents testing patterns and skills for the Full Circle project, extracted and adapted for Cline efficiency.

## Test Infrastructure

| Module | Purpose | Location |
|--------|---------|----------|
| `FullCircle.DataCase` | Domain context tests | `test/support/data_case.ex` |
| `FullCircleWeb.ConnCase` | LiveView & controller tests | `test/support/conn_case.ex` |

## Domain Context Test Pattern

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
      good = good_fixture(admin, company)
      contact = contact_fixture(admin, company)
      attrs = invoice_attrs(good, contact, admin, company)

      assert {:ok, %{create_invoice: inv}} = Billing.create_invoice(attrs, company, admin)
      assert inv.invoice_no =~ "INV-"
      assert Decimal.eq?(inv.invoice_amount, expected_amount)
    end
  end
end
```

## Fixture Pattern

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
          "unit_multiplier" => "0",
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

## LiveView Test Pattern

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

## Custom Test Macros

| Macro | Module | Purpose |
|-------|--------|---------|
| `test_authorise_to/2` | `DataCase` | Tests roles that ARE allowed |
| `test_not_authorise_to/2` | `DataCase` | Tests roles that are NOT allowed |
| `test_input_value/4` | `ConnCase` | Verifies form field values |
| `test_input_feedback/4` | `ConnCase` | Verifies validation error messages |

## Fixture Hierarchy

```
user_fixture()           -> User
  |
  company_fixture(user)  -> Company (with seeded accounts)
    |
    +-- contact_fixture(user, company)
    +-- good_fixture(user, company)     -> Good + Packaging + TaxCodes
    +-- account_fixture(attrs, user, company)
    +-- funds_account_fixture(user, company)  -> "Cash or Equivalent"
    +-- bank_account_fixture(user, company)   -> "Bank"
```

**Note**: Default seeded accounts do NOT include cash accounts. Use `funds_account_fixture` for receipt/payment tests.

## Cline Tips for Testing

- **Run specific test**: `execute_command` with `mix test test/full_circle/billing_test.exs:42`
- **Run all tests**: `execute_command` with `mix test`
- **Create fixture**: Use `write_to_file` for new fixture file, import existing fixtures.
- **Add test**: `replace_in_file` in test file to add new describe/test block.
- **Debug**: Use `IO.inspect` in test, run with `--trace` for detailed output.

## Authorization Testing

```elixir
# For allow_roles - list allowed roles
test_authorise_to(:create_invoice,
  ["admin", "manager", "supervisor", "clerk", "cashier"])

# For forbid_roles - list ALL roles NOT in forbid list
test_authorise_to(:create_contact,
  ["admin", "manager", "supervisor", "cashier", "clerk", "disable", "punch_camera"])
```

**Critical**: For forbid_roles, include `disable` and `punch_camera` if not forbidden.

## Common Test Pitfalls

- `unit_multiplier: "0"` in fixtures to use quantity directly.
- Use `Decimal.new("0")` for virtual fields.
- Test DB is separate; migrations run automatically.
- Fixtures create real DB records; use in setup blocks.