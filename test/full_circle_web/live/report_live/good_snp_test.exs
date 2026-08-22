defmodule FullCircleWeb.ReportLive.GoodSnPTest do
  use FullCircleWeb.ConnCase
  import Phoenix.LiveViewTest
  import FullCircle.SysFixtures
  import FullCircle.UserAccountsFixtures
  import FullCircle.BillingFixtures
  import FullCircle.ReceiveFundFixtures
  import FullCircle.BillPayFixtures

  setup %{conn: conn} do
    user = user_fixture()
    company = company_fixture(user, %{})
    %{conn: log_in_user(conn, user), user: user, company: company}
  end

  test "sales type lists invoice and cash receipt lines", %{
    conn: conn,
    company: company,
    user: user
  } do
    invoice = invoice_fixture(company, user)
    receipt = receipt_fixture(company, user)

    {:ok, lv, _html} =
      live(conn, ~p"/companies/#{company.id}/good_snp?search[type]=sales")

    html = render_async(lv)
    assert html =~ "Customer"
    assert html =~ invoice.invoice_no
    assert html =~ receipt.receipt_no
  end

  test "purchases type lists pur invoice and cash payment lines", %{
    conn: conn,
    company: company,
    user: user
  } do
    pur_invoice = pur_invoice_fixture(company, user)
    payment = payment_fixture(company, user)

    {:ok, lv, _html} =
      live(conn, ~p"/companies/#{company.id}/good_snp?search[type]=purchases")

    html = render_async(lv)
    assert html =~ "Vendor"
    assert html =~ pur_invoice.pur_invoice_no
    assert html =~ payment.payment_no
    refute html =~ "Customer"
  end

  test "custom category shows pattern fields and filters by name/description ilike", %{
    conn: conn,
    company: company,
    user: user
  } do
    import Ecto.Query

    contact = contact_fixture(company, user, %{"name" => "Custom Cat Customer"})

    egg_good = good_fixture(company, user, %{"name" => "Custom Grade Egg"})
    misc_good = good_fixture(company, user, %{"name" => "Custom Misc"})
    other_good = good_fixture(company, user, %{"name" => "Custom Other"})

    sales_acct = FullCircle.Accounting.get_account_by_name("General Sales", company, user)

    sales_tc =
      FullCircle.Repo.one!(
        from tc in FullCircle.Accounting.TaxCode,
          where: tc.company_id == ^company.id and tc.code == "NoSTax"
      )

    for {good, desc} <- [
          {egg_good, nil},
          {misc_good, "spoilt egg disposal"},
          {other_good, "nothing related"}
        ] do
      attrs =
        invoice_attrs(contact, good, sales_acct, sales_tc, tax_rate: "0")
        |> put_in(["invoice_details", "0", "descriptions"], desc)

      {:ok, _} = FullCircle.Billing.create_invoice(attrs, company, user)
    end

    qs =
      URI.encode_query(%{
        "search[type]" => "sales",
        "search[category]" => "custom",
        "search[name_ilike]" => "%grade egg%",
        "search[desc_ilike]" => "%egg disposal%"
      })

    {:ok, lv, _html} = live(conn, "/companies/#{company.id}/good_snp?" <> qs)

    # Custom mode renders the two pattern fields, not the plain good list
    assert has_element?(lv, "#search_name_ilike")
    assert has_element?(lv, "#search_desc_ilike")
    refute has_element?(lv, "#search_goods")

    html = render_async(lv)
    assert html =~ "Custom Grade Egg"
    assert html =~ "Custom Misc"
    assert html =~ "spoilt egg disposal"
    refute html =~ "Custom Other"
  end

  test "descriptions column renders in exact mode too", %{
    conn: conn,
    company: company,
    user: user
  } do
    import Ecto.Query

    contact = contact_fixture(company, user, %{"name" => "Desc Col Customer"})

    good = good_fixture(company, user, %{"name" => "DescColGood"})
    sales_acct = FullCircle.Accounting.get_account_by_name("General Sales", company, user)

    sales_tc =
      FullCircle.Repo.one!(
        from tc in FullCircle.Accounting.TaxCode,
          where: tc.company_id == ^company.id and tc.code == "NoSTax"
      )

    attrs =
      invoice_attrs(contact, good, sales_acct, sales_tc, tax_rate: "0")
      |> put_in(["invoice_details", "0", "descriptions"], "visible line note")

    {:ok, _} = FullCircle.Billing.create_invoice(attrs, company, user)

    {:ok, lv, _html} = live(conn, ~p"/companies/#{company.id}/good_snp")
    html = render_async(lv)
    assert html =~ "visible line note"
  end

  test "legacy /good_sales route renders the combined page defaulting to sales", %{
    conn: conn,
    company: company,
    user: user
  } do
    invoice = invoice_fixture(company, user)

    {:ok, lv, _html} = live(conn, ~p"/companies/#{company.id}/good_sales")

    html = render_async(lv)
    assert html =~ "Customer"
    assert html =~ invoice.invoice_no
  end
end
