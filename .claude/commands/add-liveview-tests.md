Add comprehensive LiveView tests for the feature: $ARGUMENTS

## Instructions

1. **Identify the LiveView modules**: Read the LiveView files in `lib/full_circle_web/live/<feature>/`
2. **Check existing tests**: Read `test/full_circle_web/live/` for existing tests
3. **Check the router**: Read `lib/full_circle_web/router.ex` for route paths
4. **Understand the form fields**: Read the form.ex and detail_component.ex to know what fields exist

## Test Categories

### Form Tests (New)
```elixir
describe "New" do
  setup %{conn: conn, comp: comp} do
    {:ok, lv, html} = live(conn, ~p"/companies/#{comp.id}/<route>/new")
    %{conn: conn, lv: lv, html: html}
  end

  test "renders new form", %{html: html} do
    assert html =~ "Creating"  # or appropriate title
  end

  test "save valid data", %{conn: conn, lv: lv} do
    {:ok, _, html} =
      lv
      |> form("#<form_id>", <entity>: valid_attrs)
      |> render_submit()
      |> follow_redirect(conn)
    assert html =~ "expected text"
  end

  test "save invalid data", %{lv: lv} do
    html =
      lv
      |> form("#<form_id>", <entity>: %{required_field: ""})
      |> render_submit()
    assert html =~ "can't be blank"
  end
end
```

### Form Tests (Edit)
```elixir
describe "Edit" do
  setup %{conn: conn, comp: comp, obj: obj} do
    {:ok, lv, html} = live(conn, ~p"/companies/#{comp.id}/<route>/#{obj.id}/edit")
    %{conn: conn, lv: lv, html: html}
  end

  test "renders edit form with data", %{html: html} do
    assert html =~ "Editing"  # or appropriate title
  end

  test "form layout", %{html: html} do
    # Verify all expected labels are present
    assert html =~ "Field Label"
  end
end
```

### Data Value Tests
```elixir
describe "data value" do
  setup %{conn: conn, comp: comp, obj: obj} do
    {:ok, lv, html} = live(conn, ~p"/companies/#{comp.id}/<route>/#{obj.id}/edit")
    %{conn: conn, lv: lv, html: html, obj: obj}
  end

  # For text inputs
  test_input_value("<form_id>", "input", :text, "field_name")
  # For select dropdowns
  test_input_value("<form_id>", "select", :text, "field_name")
  # For textareas
  test_input_value("<form_id>", "textarea", :text, "field_name")
  # For number fields
  test_input_value("<form_id>", "input", :number, "field_name")
end
```

### Data Validation Tests
```elixir
describe "data validation" do
  setup %{conn: conn, comp: comp} do
    {:ok, lv, html} = live(conn, ~p"/companies/#{comp.id}/<route>/new")
    %{conn: conn, lv: lv, html: html}
  end

  test_input_feedback("<form_id>", "field", "", "can't be blank")
  test_input_feedback("<form_id>", "field", "duplicate_value", "has already been taken")
end
```

## Setup Pattern
```elixir
defmodule FullCircleWeb.<Feature>LiveTest do
  use FullCircleWeb.ConnCase
  import Phoenix.LiveViewTest
  import FullCircle.SysFixtures
  import FullCircle.UserAccountsFixtures
  # Import relevant fixtures

  setup %{conn: conn} do
    user = user_fixture()
    comp = company_fixture(user, %{})
    obj = <entity>_fixture(attrs, user, comp)
    %{conn: log_in_user(conn, user), user: user, comp: comp, obj: obj}
  end
end
```

## Key Conventions
- Form ID typically matches entity name: `#invoice`, `#account`, `#contact`
- Use `log_in_user(conn, user)` from ConnCase to authenticate
- Route paths use `~p"/companies/#{comp.id}/<route>"`
- Use `render_submit()` for form submission, `render_change()` for validation
- `follow_redirect(conn)` after successful submit
- Run with: `mise exec -- mix test <file>`
