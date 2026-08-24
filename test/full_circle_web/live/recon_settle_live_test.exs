defmodule FullCircleWeb.ReconSettleLiveTest do
  use FullCircleWeb.ConnCase

  import Phoenix.LiveViewTest
  import Ecto.Query
  import FullCircle.SysFixtures
  import FullCircle.UserAccountsFixtures
  import FullCircle.AccountingFixtures
  import FullCircle.BillingFixtures

  alias FullCircle.Repo
  alias FullCircle.{Accounting, BankReconciliation}
  alias FullCircle.BankReconciliation.BankStatementLine

  setup %{conn: conn} do
    user = user_fixture()
    company = company_fixture(user, %{})
    account = account_fixture(%{name: "PBB Current", account_type: "Bank"}, company, user)
    contact = contact_fixture(company, user)

    %{conn: log_in_user(conn, user), user: user, company: company, account: account, contact: contact}
  end

  defp import_line(account, company, attrs) do
    line =
      Map.merge(
        %{
          statement_date: Date.add(Date.utc_today(), -5),
          description: "IBG SETTLE LINE",
          cheque_no: "",
          amount: Decimal.new("250.50"),
          reference: ""
        },
        attrs
      )

    {1, _} = BankReconciliation.import_statement(account.id, company.id, [line], "pdf")

    from(sl in BankStatementLine,
      where: sl.account_id == ^account.id,
      where: sl.description == ^line.description
    )
    |> Repo.one!()
  end

  defp invoice_for(contact, amount, company, user) do
    good = good_fixture(company, user)
    sales_acct = Accounting.get_account_by_name("General Sales", company, user)

    sales_tc =
      Repo.one!(
        from(tc in Accounting.TaxCode,
          where: tc.company_id == ^company.id and tc.code == "NoSTax"
        )
      )

    attrs =
      invoice_attrs(contact, good, sales_acct, sales_tc,
        quantity: "1",
        unit_price: amount,
        tax_rate: "0"
      )

    {:ok, %{create_invoice: invoice}} = FullCircle.Billing.create_invoice(attrs, company, user)
    invoice
  end

  defp recon_path(company, account) do
    from = Date.add(Date.utc_today(), -30) |> Date.to_iso8601()
    to = Date.utc_today() |> Date.to_iso8601()

    ~p"/companies/#{company.id}/bank_reconciliation?#{%{"search[name]" => account.name, "search[f_date]" => from, "search[t_date]" => to}}"
  end

  test "settle invoices from a received statement line creates a matched RC", %{
    conn: conn,
    company: company,
    account: account,
    contact: contact,
    user: user
  } do
    invoice = invoice_for(contact, "250.50", company, user)
    line = import_line(account, company, %{amount: Decimal.new("250.50")})

    {:ok, lv, _} = live(conn, recon_path(company, account))

    render_click(lv, "toggle_stmt", %{"id" => line.id})
    html = render(lv)
    assert html =~ "Settle Invoices"
    refute html =~ "Settle Bills"

    render_click(lv, "start_settle_doc", %{"doc" => "Receipt"})
    assert has_element?(lv, "#recon-settle-panel")

    # load the contact's outstanding docs
    lv
    |> form("#recon-settle-form", %{"contact" => contact.name})
    |> render_change()

    html = render_click(lv, "settle_load_docs", %{})
    assert html =~ invoice.invoice_no

    # tick the invoice — allocation equals the statement total
    row_id =
      Accounting.query_transactions_for_matching(
        contact.id,
        Date.add(Date.utc_today(), -366) |> Date.to_iso8601(),
        Date.utc_today() |> Date.to_iso8601(),
        company,
        user
      )
      |> hd()
      |> Map.fetch!(:transaction_id)

    render_click(lv, "settle_toggle_doc", %{"id" => row_id})

    html = render_click(lv, "confirm_settle_doc", %{})
    assert html =~ "created and matched"
    assert html =~ "RC-"

    line = Repo.get!(BankStatementLine, line.id)
    assert line.match_group_id
  end

  test "post-diff control matches selection plus an auto fee journal", %{
    conn: conn,
    company: company,
    account: account,
    user: user
  } do
    txn =
      %FullCircle.Accounting.Transaction{}
      |> FullCircle.Accounting.Transaction.changeset(%{
        doc_type: "Receipt",
        doc_no: "RC#{System.unique_integer([:positive])}",
        doc_date: Date.add(Date.utc_today(), -10),
        particulars: "VISA takings",
        amount: Decimal.new("100.00"),
        company_id: company.id,
        account_id: account.id
      })
      |> Repo.insert!()

    line =
      import_line(account, company, %{
        amount: Decimal.new("98.00"),
        description: "VISA SETTLEMENT NET"
      })

    account_fixture(%{name: "Card Commission", account_type: "Expenses"}, company, user)

    {:ok, lv, _} = live(conn, recon_path(company, account))

    render_click(lv, "toggle_stmt", %{"id" => line.id})
    html = render_click(lv, "toggle_txn", %{"id" => txn.id})
    assert html =~ "Post Diff"

    lv
    |> form("#recon-diff-form", %{"diff_account" => "Card Commission"})
    |> render_change()

    html = render_click(lv, "match_with_difference", %{})
    assert html =~ "matched with difference"

    line = Repo.get!(FullCircle.BankReconciliation.BankStatementLine, line.id)
    assert line.match_group_id

    group_amounts =
      Repo.all(
        from(t in FullCircle.Accounting.Transaction,
          where: t.match_group_id == ^line.match_group_id,
          select: t.amount
        )
      )

    assert Enum.any?(group_amounts, &Decimal.eq?(&1, Decimal.new("-2.00")))
  end

  test "no post-diff control when selection totals are equal", %{
    conn: conn,
    company: company,
    account: account
  } do
    txn =
      %FullCircle.Accounting.Transaction{}
      |> FullCircle.Accounting.Transaction.changeset(%{
        doc_type: "Receipt",
        doc_no: "RC#{System.unique_integer([:positive])}",
        doc_date: Date.add(Date.utc_today(), -10),
        particulars: "EXACT",
        amount: Decimal.new("98.00"),
        company_id: company.id,
        account_id: account.id
      })
      |> Repo.insert!()

    line = import_line(account, company, %{amount: Decimal.new("98.00")})

    {:ok, lv, _} = live(conn, recon_path(company, account))

    render_click(lv, "toggle_stmt", %{"id" => line.id})
    html = render_click(lv, "toggle_txn", %{"id" => txn.id})

    refute html =~ "Post Diff"
    assert html =~ "Match Selected"
  end

  test "Match Selected hides when selection totals differ", %{
    conn: conn,
    company: company,
    account: account
  } do
    txn =
      %FullCircle.Accounting.Transaction{}
      |> FullCircle.Accounting.Transaction.changeset(%{
        doc_type: "Receipt",
        doc_no: "RC#{System.unique_integer([:positive])}",
        doc_date: Date.add(Date.utc_today(), -10),
        particulars: "GROSS",
        amount: Decimal.new("100.00"),
        company_id: company.id,
        account_id: account.id
      })
      |> Repo.insert!()

    line = import_line(account, company, %{amount: Decimal.new("98.00")})

    {:ok, lv, _} = live(conn, recon_path(company, account))

    render_click(lv, "toggle_stmt", %{"id" => line.id})
    render_click(lv, "toggle_txn", %{"id" => txn.id})

    refute has_element?(lv, "button[phx-click=match_selected]")
    assert has_element?(lv, "#recon-diff-form")
  end

  test "Auto-Match hides once a transaction is selected", %{
    conn: conn,
    company: company,
    account: account
  } do
    txn =
      %FullCircle.Accounting.Transaction{}
      |> FullCircle.Accounting.Transaction.changeset(%{
        doc_type: "Receipt",
        doc_no: "RC#{System.unique_integer([:positive])}",
        doc_date: Date.add(Date.utc_today(), -10),
        particulars: "MANUAL",
        amount: Decimal.new("50.00"),
        company_id: company.id,
        account_id: account.id
      })
      |> Repo.insert!()

    {:ok, lv, _} = live(conn, recon_path(company, account))
    assert has_element?(lv, "button[phx-click=auto_match]")

    render_click(lv, "toggle_txn", %{"id" => txn.id})
    refute has_element?(lv, "button[phx-click=auto_match]")

    # deselect — auto match returns
    render_click(lv, "toggle_txn", %{"id" => txn.id})
    assert has_element?(lv, "button[phx-click=auto_match]")
  end

  test "negative selection offers Settle Bills instead", %{
    conn: conn,
    company: company,
    account: account
  } do
    line = import_line(account, company, %{amount: Decimal.new("-99.00")})

    {:ok, lv, _} = live(conn, recon_path(company, account))

    html = render_click(lv, "toggle_stmt", %{"id" => line.id})
    assert html =~ "Settle Bills"
    refute html =~ "Settle Invoices"
  end

  test "confirm without full allocation shows an error and creates nothing", %{
    conn: conn,
    company: company,
    account: account,
    contact: contact
  } do
    line = import_line(account, company, %{amount: Decimal.new("250.50")})

    {:ok, lv, _} = live(conn, recon_path(company, account))
    render_click(lv, "toggle_stmt", %{"id" => line.id})
    render_click(lv, "start_settle_doc", %{"doc" => "Receipt"})

    lv
    |> form("#recon-settle-form", %{"contact" => contact.name})
    |> render_change()

    render_click(lv, "settle_load_docs", %{})

    html = render_click(lv, "confirm_settle_doc", %{})
    assert html =~ "must equal the statement total"
    assert Repo.get!(BankStatementLine, line.id).match_group_id == nil
  end
end
