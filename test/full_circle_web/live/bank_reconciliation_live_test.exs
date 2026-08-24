defmodule FullCircleWeb.BankReconciliationLiveTest do
  use FullCircleWeb.ConnCase

  import Phoenix.LiveViewTest
  import Ecto.Query
  import FullCircle.SysFixtures
  import FullCircle.UserAccountsFixtures
  import FullCircle.AccountingFixtures

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
          cheque_no: "123456",
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

  defp recon_path(company, account) do
    ~p"/companies/#{company.id}/bank_reconciliation?#{%{"search[name]" => account.name, "search[f_date]" => "2026-04-01", "search[t_date]" => "2026-04-30"}}"
  end

  describe "edit imported statement line" do
    test "saves corrected date and amount", %{
      conn: conn,
      company: company,
      account: account
    } do
      line = import_line(account, company, %{description: "IBG WRONG AMOUNT"})

      {:ok, lv, html} = live(conn, recon_path(company, account))
      assert html =~ "IBG WRONG AMOUNT"

      lv
      |> element("#stmt-#{line.id} a[phx-click=start_edit_stmt]")
      |> render_click()

      html =
        lv
        |> form("#edit-stmt-form",
          edit: %{
            statement_date: "2026-04-16",
            description: "IBG CORRECTED",
            cheque_no: "654321",
            amount: "-250.00"
          }
        )
        |> render_submit()

      assert html =~ "IBG CORRECTED"
      assert html =~ "16-04-2026"
      refute html =~ "IBG WRONG AMOUNT"

      updated = Repo.get!(BankStatementLine, line.id)
      assert updated.statement_date == ~D[2026-04-16]
      assert Decimal.eq?(updated.amount, Decimal.new("-250.00"))
    end

    test "edit button does not stop click propagation", %{
      conn: conn,
      company: company,
      account: account
    } do
      import_line(account, company, %{description: "CLICK EDIT"})

      {:ok, _lv, html} = live(conn, recon_path(company, account))

      # LiveView binds click on window. stopPropagation on the button swallows
      # start_edit_stmt in the real browser (LiveViewTest.render_click does not).
      refute html =~ ~r/phx-click="start_edit_stmt"[^>]*onclick=/
    end

    test "does not offer edit on a matched line", %{
      conn: conn,
      company: company,
      account: account
    } do
      line = import_line(account, company, %{description: "ALREADY MATCHED"})

      Repo.get!(BankStatementLine, line.id)
      |> Ecto.Changeset.change(match_group_id: Ecto.UUID.generate())
      |> Repo.update!()

      {:ok, lv, html} = live(conn, recon_path(company, account))
      assert html =~ "ALREADY MATCHED"
      refute has_element?(lv, "#stmt-#{line.id} a[phx-click=start_edit_stmt]")
      refute has_element?(lv, "#stmt-#{line.id} button[phx-click=start_edit_stmt]")
    end
  end

  describe "delete selected statement lines" do
    test "removes the selected unmatched line", %{
      conn: conn,
      company: company,
      account: account
    } do
      line = import_line(account, company, %{description: "LINE TO DELETE"})
      import_line(account, company, %{description: "LINE TO KEEP"})

      {:ok, lv, html} = live(conn, recon_path(company, account))
      assert html =~ "LINE TO DELETE"
      assert html =~ "LINE TO KEEP"

      lv
      |> element("#stmt-#{line.id} [phx-click=toggle_stmt]")
      |> render_click()

      html =
        lv
        |> element("button[phx-click=delete_selected]")
        |> render_click()

      refute html =~ "LINE TO DELETE"
      assert html =~ "LINE TO KEEP"
      assert Repo.get(BankStatementLine, line.id) == nil
    end
  end

  describe "auto match suggestions" do
    test "highlights suggested statement and book rows and lifts them to the top", %{
      conn: conn,
      company: company,
      account: account
    } do
      import_line(account, company, %{
        description: "UNMATCHED EARLIER LINE",
        amount: Decimal.new("-10.00"),
        statement_date: ~D[2026-04-10]
      })

      line =
        import_line(account, company, %{
          description: "IBG AUTO MATCH ME",
          amount: Decimal.new("-250.50"),
          statement_date: ~D[2026-04-15]
        })

      insert_book_txn!(
        company,
        account,
        Decimal.new("-99.00"),
        ~D[2026-04-10],
        "EARLIER BOOK TXN"
      )

      txn =
        insert_book_txn!(
          company,
          account,
          Decimal.new("-250.50"),
          ~D[2026-04-15],
          "AUTO MATCH BOOK TXN"
        )

      {:ok, lv, html} = live(conn, recon_path(company, account))
      assert html =~ "IBG AUTO MATCH ME"
      refute html =~ "bg-yellow-200"
      refute html =~ "Confirm All Suggestions"

      html =
        lv
        |> element("button[phx-click=auto_match]")
        |> render_click()

      assert html =~ "Confirm All Suggestions"
      assert has_element?(lv, "#stmt-#{line.id}.bg-yellow-200")
      assert has_element?(lv, "#txn-#{txn.id}.bg-yellow-200")
      assert has_element?(lv, "#stmt-#{line.id}", "Suggested")
      assert has_element?(lv, "#txn-#{txn.id}", "Suggested")

      # Suggested rows must be visible without scrolling past unmatched ones.
      assert html =~ ~r/IBG AUTO MATCH ME[\s\S]*UNMATCHED EARLIER LINE/
      assert html =~ ~r/AUTO MATCH BOOK TXN[\s\S]*EARLIER BOOK TXN/

      html =
        lv
        |> element("button[phx-click=confirm_all_suggested]")
        |> render_click()

      assert html =~ "matches confirmed"
      assert has_element?(lv, "#stmt-#{line.id}", "Matched")
      assert has_element?(lv, "#txn-#{txn.id}", "Matched")
    end
  end

  defp insert_book_txn!(company, account, amount, date, particulars) do
    %Transaction{}
    |> Transaction.changeset(%{
      doc_type: "Journal",
      doc_no: "J#{System.unique_integer([:positive])}",
      doc_date: date,
      particulars: particulars,
      amount: amount,
      company_id: company.id,
      account_id: account.id
    })
    |> Repo.insert!()
  end

  describe "create document from statement lines" do
    test "Create Payment navigates to the seeded Payment form for negative lines", %{
      conn: conn,
      company: company,
      account: account
    } do
      line =
        import_line(account, company, %{
          description: "IBG PAYMENT NO DOC",
          amount: Decimal.new("-250.50")
        })

      {:ok, lv, _html} = live(conn, recon_path(company, account))

      html = render_click(lv, "toggle_stmt", %{"id" => line.id})
      assert html =~ "Create Payment"
      refute html =~ "Create Receipt"

      render_click(lv, "create_doc_from_stmt", %{"doc" => "Payment"})
      {path, _flash} = assert_redirect(lv)
      assert path =~ "/companies/#{company.id}/Payment/new?recon="

      recon =
        path
        |> URI.parse()
        |> Map.fetch!(:query)
        |> URI.decode_query()
        |> Map.fetch!("recon")
        |> Jason.decode!()

      assert recon["stmt_ids"] == [line.id]
      assert recon["amount"] == "250.50"
      assert recon["stmt_total"] == "-250.50"
      assert recon["date"] == "2026-04-15"
      assert recon["bank_account_id"] == account.id
      assert recon["bank_account_name"] == account.name
      assert recon["descriptions"] == "IBG PAYMENT NO DOC"
      assert recon["return"]["name"] == account.name
      assert recon["return"]["f_date"] == "2026-04-01"
      assert recon["return"]["t_date"] == "2026-04-30"
    end

    test "Create Receipt navigates to the seeded Receipt form for positive lines", %{
      conn: conn,
      company: company,
      account: account
    } do
      line =
        import_line(account, company, %{
          description: "IBG CREDIT CUSTOMER PAID",
          amount: Decimal.new("880.00")
        })

      {:ok, lv, _html} = live(conn, recon_path(company, account))

      html = render_click(lv, "toggle_stmt", %{"id" => line.id})
      assert html =~ "Create Receipt"
      refute html =~ "Create Payment"

      render_click(lv, "create_doc_from_stmt", %{"doc" => "Receipt"})
      {path, _flash} = assert_redirect(lv)
      assert path =~ "/companies/#{company.id}/Receipt/new?recon="
    end

    test "offers neither button for a mixed-sign selection", %{
      conn: conn,
      company: company,
      account: account
    } do
      neg = import_line(account, company, %{description: "NEG", amount: Decimal.new("-10.00")})
      pos = import_line(account, company, %{description: "POS", amount: Decimal.new("10.00")})

      {:ok, lv, _html} = live(conn, recon_path(company, account))

      render_click(lv, "toggle_stmt", %{"id" => neg.id})
      html = render_click(lv, "toggle_stmt", %{"id" => pos.id})

      refute html =~ "Create Payment"
      refute html =~ "Create Receipt"
    end
  end
end
