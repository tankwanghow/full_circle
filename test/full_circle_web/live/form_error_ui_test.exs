defmodule FullCircleWeb.FormErrorUiTest do
  # Form errors show on their own fields; the Save button counts them and
  # jumps between them (ErrorJump hook). No summary box above the form.
  use FullCircleWeb.ConnCase
  import Phoenix.LiveViewTest
  import FullCircle.BillingFixtures
  import Ecto.Query

  setup %{conn: conn} do
    %{admin: admin, company: company} = billing_setup()
    %{conn: log_in_user(conn, admin), admin: admin, company: company}
  end

  defp new_payment(conn, company), do: live(conn, ~p"/companies/#{company.id}/Payment/new")

  test "no summary box; bad fields carry aria-invalid and their own message", %{
    conn: conn,
    company: company
  } do
    {:ok, lv, _} = new_payment(conn, company)

    html =
      render_change(lv, "validate", %{
        "payment" => %{"contact_name" => "", "funds_amount" => "10"}
      })

    refute html =~ "Please fix the following errors"
    refute has_element?(lv, "#error-summary")
    assert has_element?(lv, "#payment_contact_name[aria-invalid=true]")
    assert has_element?(lv, "#payment_funds_amount:not([aria-invalid])")
  end

  test "Save becomes an error counter that carries the jump hook", %{
    conn: conn,
    company: company
  } do
    {:ok, lv, _} = new_payment(conn, company)
    assert has_element?(lv, "#save-button[phx-hook=ErrorJump][data-errors='0']", "Save")

    render_change(lv, "validate", %{"payment" => %{"contact_name" => ""}})

    assert has_element?(lv, "#save-button[type=button][phx-hook=ErrorJump]", "Errors")
    refute has_element?(lv, "#save-button[data-errors='0']")
  end

  test "the balance error lands on the balance field, not beside the button", %{
    conn: conn,
    admin: admin,
    company: company
  } do
    contact = contact_fixture(company, admin)
    good = good_fixture(company, admin)
    pur_acct = FullCircle.Accounting.get_account_by_name("General Purchases", company, admin)
    funds = FullCircle.BillPayFixtures.pay_funds_account_fixture(company, admin)

    no_ptax =
      FullCircle.Repo.one!(
        from tc in FullCircle.Accounting.TaxCode,
          where: tc.company_id == ^company.id and tc.code == "NoPTax"
      )

    # Every header and line field filled (as a browser sends them); only the
    # computed balance is wrong: RM 1 paid for a RM 50 line.
    params =
      FullCircle.BillPayFixtures.payment_attrs(contact, good, pur_acct, no_ptax, funds,
        tax_rate: "0",
        quantity: "1",
        unit_price: "50.00",
        funds_amount: "1.00"
      )
      |> Map.put("payment_no", "...new...")

    {:ok, lv, _} = new_payment(conn, company)
    render_change(lv, "validate", %{"payment" => params})

    # The balance is shown as a (readonly) field, so its error is inline.
    assert has_element?(lv, "#save-button", "1 Error")
    assert has_element?(lv, "#payment_payment_balance[aria-invalid=true]")
    refute has_element?(lv, "#save-orphan-errors")
  end

  test "an error on a field the form doesn't render shows beside the button" do
    cs =
      {%{}, %{name: :string, total: :decimal, balance: :decimal}}
      |> Ecto.Changeset.cast(%{"name" => "", "total" => "5"}, [:name, :total, :balance])
      |> Ecto.Changeset.validate_required([:name])
      |> Ecto.Changeset.add_error(:balance, "must be greater than or equal to 0")
      |> Map.put(:action, :validate)

    html =
      render_component(&FullCircleWeb.CoreComponents.save_button/1,
        form: Phoenix.Component.to_form(cs, as: "x"),
        label: "Save"
      )

    assert html =~ ~s(id="save-orphan-errors")
    assert html =~ "Balance must be greater than or equal to 0"
    refute html =~ "Name can"
    assert html =~ "2 Errors ↓"
  end
end
