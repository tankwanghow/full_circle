defmodule FullCircleWeb.ReconDocPrefillLiveTest do
  use FullCircleWeb.ConnCase

  import Phoenix.LiveViewTest
  import Ecto.Query
  import FullCircle.SysFixtures
  import FullCircle.UserAccountsFixtures
  import FullCircle.AccountingFixtures
  import FullCircle.BillingFixtures

  alias FullCircle.Repo
  alias FullCircle.BankReconciliation
  alias FullCircle.BankReconciliation.BankStatementLine
  alias FullCircle.Accounting.Transaction

  setup %{conn: conn} do
    user = user_fixture()
    company = company_fixture(user, %{})
    account = account_fixture(%{name: "PBB Current", account_type: "Bank"}, company, user)

    %{conn: log_in_user(conn, user), user: user, company: company, account: account}
  end

  defp import_line(account, company, attrs) do
    line =
      Map.merge(
        %{
          statement_date: ~D[2026-04-15],
          description: "IBG PAYMENT ABC SDN BHD",
          cheque_no: "",
          amount: Decimal.new("-250.50"),
          reference: "ref-1"
        },
        attrs
      )

    {1, _} = BankReconciliation.import_statement(account.id, company.id, [line], "pdf")

    from(sl in BankStatementLine,
      where: sl.account_id == ^account.id,
      where: sl.company_id == ^company.id,
      where: sl.description == ^line.description,
      order_by: [desc: sl.inserted_at],
      limit: 1
    )
    |> Repo.one!()
  end

  defp recon_payload(account, lines) do
    stmt_total = Enum.reduce(lines, Decimal.new(0), &Decimal.add(&1.amount, &2))

    %{
      "stmt_ids" => Enum.map(lines, & &1.id),
      "date" => lines |> Enum.map(& &1.statement_date) |> Enum.max(Date) |> Date.to_iso8601(),
      "amount" => stmt_total |> Decimal.abs() |> Decimal.to_string(),
      "stmt_total" => Decimal.to_string(stmt_total),
      "bank_account_id" => account.id,
      "bank_account_name" => account.name,
      "descriptions" => lines |> Enum.map(& &1.description) |> Enum.uniq() |> Enum.join("; "),
      "return" => %{"name" => account.name, "f_date" => "2026-04-01", "t_date" => "2026-04-30"}
    }
    |> Jason.encode!()
  end

  defp recon_return_url(company, account) do
    qry = %{
      "search[name]" => account.name,
      "search[f_date]" => "2026-04-01",
      "search[t_date]" => "2026-04-30"
    }

    "/companies/#{company.id}/bank_reconciliation?#{URI.encode_query(qry)}"
  end

  defp payment_attrs_for(company, user, funds_account, amount) do
    contact = contact_fixture(company, user)
    good = good_fixture(company, user)
    pur_acct = FullCircle.Accounting.get_account_by_name("General Purchases", company, user)

    pur_tc =
      Repo.one!(
        from(tc in FullCircle.Accounting.TaxCode,
          where: tc.company_id == ^company.id and tc.code == "NoPTax"
        )
      )

    FullCircle.BillPayFixtures.payment_attrs(
      contact,
      good,
      pur_acct,
      pur_tc,
      funds_account,
      quantity: "1",
      unit_price: amount,
      funds_amount: amount,
      tax_rate: "0"
    )
    |> Map.put("payment_date", "2026-04-15")
  end

  describe "Payment form seeded from bank recon" do
    test "prefills funds account, amount, date and descriptions", %{
      conn: conn,
      company: company,
      account: account
    } do
      line = import_line(account, company, %{})

      {:ok, _view, html} =
        live(
          conn,
          "/companies/#{company.id}/Payment/new?recon=#{recon_payload(account, [line])}"
        )

      assert html =~ "PBB Current"
      assert html =~ "250.5"
      assert html =~ "2026-04-15"
      assert html =~ "IBG PAYMENT ABC SDN BHD"
    end

    test "on save, matches the statement lines and returns to recon", %{
      conn: conn,
      user: user,
      company: company,
      account: account
    } do
      line = import_line(account, company, %{})

      {:ok, view, _html} =
        live(
          conn,
          "/companies/#{company.id}/Payment/new?recon=#{recon_payload(account, [line])}"
        )

      attrs = payment_attrs_for(company, user, account, "250.50")

      view
      |> element("#object-form")
      |> render_submit(%{"payment" => attrs})

      assert_redirect(view, recon_return_url(company, account))

      line = Repo.get!(BankStatementLine, line.id)
      assert line.match_group_id

      txn =
        Repo.one!(
          from(t in Transaction,
            where: t.account_id == ^account.id,
            where: t.doc_type == "Payment",
            where: t.match_group_id == ^line.match_group_id
          )
        )

      assert txn.reconciled == true
      assert Decimal.eq?(txn.amount, Decimal.new("-250.50"))
    end

    test "does not match when the saved amount differs from the statement", %{
      conn: conn,
      user: user,
      company: company,
      account: account
    } do
      line = import_line(account, company, %{})

      {:ok, view, _html} =
        live(
          conn,
          "/companies/#{company.id}/Payment/new?recon=#{recon_payload(account, [line])}"
        )

      attrs = payment_attrs_for(company, user, account, "200.00")

      view
      |> element("#object-form")
      |> render_submit(%{"payment" => attrs})

      assert_redirect(view, recon_return_url(company, account))

      line = Repo.get!(BankStatementLine, line.id)
      assert line.match_group_id == nil

      txn =
        Repo.one!(
          from(t in Transaction,
            where: t.account_id == ^account.id,
            where: t.doc_type == "Payment"
          )
        )

      assert txn.reconciled == false
    end
  end

  defp receipt_attrs_for(company, user, funds_account, amount) do
    contact = contact_fixture(company, user)
    good = good_fixture(company, user)
    sales_acct = FullCircle.Accounting.get_account_by_name("General Sales", company, user)

    sales_tc =
      Repo.one!(
        from(tc in FullCircle.Accounting.TaxCode,
          where: tc.company_id == ^company.id and tc.code == "NoSTax"
        )
      )

    FullCircle.ReceiveFundFixtures.receipt_attrs_with_funds(
      contact,
      good,
      sales_acct,
      sales_tc,
      funds_account,
      quantity: "1",
      unit_price: amount,
      funds_amount: amount,
      tax_rate: "0"
    )
    |> Map.put("receipt_date", "2026-04-18")
  end

  describe "Receipt form seeded from bank recon" do
    test "prefills funds account, amount, date and descriptions", %{
      conn: conn,
      company: company,
      account: account
    } do
      line =
        import_line(account, company, %{
          description: "IBG CREDIT XYZ TRADING",
          statement_date: ~D[2026-04-18],
          amount: Decimal.new("880.00")
        })

      {:ok, _view, html} =
        live(
          conn,
          "/companies/#{company.id}/Receipt/new?recon=#{recon_payload(account, [line])}"
        )

      assert html =~ "PBB Current"
      assert html =~ "880"
      assert html =~ "2026-04-18"
      assert html =~ "IBG CREDIT XYZ TRADING"
    end

    test "on save, matches the statement line and returns to recon", %{
      conn: conn,
      user: user,
      company: company,
      account: account
    } do
      line =
        import_line(account, company, %{
          description: "IBG CREDIT XYZ TRADING",
          statement_date: ~D[2026-04-18],
          amount: Decimal.new("880.00")
        })

      {:ok, view, _html} =
        live(
          conn,
          "/companies/#{company.id}/Receipt/new?recon=#{recon_payload(account, [line])}"
        )

      attrs = receipt_attrs_for(company, user, account, "880.00")

      view
      |> element("#object-form")
      |> render_submit(%{"receipt" => attrs})

      assert_redirect(view, recon_return_url(company, account))

      line = Repo.get!(BankStatementLine, line.id)
      assert line.match_group_id

      txn =
        Repo.one!(
          from(t in Transaction,
            where: t.account_id == ^account.id,
            where: t.doc_type == "Receipt",
            where: t.match_group_id == ^line.match_group_id
          )
        )

      assert txn.reconciled == true
      assert Decimal.eq?(txn.amount, Decimal.new("880.00"))
    end
  end
end
