defmodule FullCircle.BankReconciliationSettleTest do
  use FullCircle.DataCase

  alias FullCircle.Repo
  alias FullCircle.{Accounting, BankReconciliation}
  alias FullCircle.BankReconciliation.BankStatementLine
  alias FullCircle.Accounting.Transaction

  import FullCircle.SysFixtures
  import FullCircle.UserAccountsFixtures
  import FullCircle.AccountingFixtures
  import FullCircle.BillingFixtures

  setup do
    admin = user_fixture()
    company = company_fixture(admin, %{})
    account = account_fixture(%{name: "PBB Current", account_type: "Bank"}, company, admin)
    contact = contact_fixture(company, admin)

    %{admin: admin, company: company, account: account, contact: contact}
  end

  defp import_line(account, company, attrs) do
    line =
      Map.merge(
        %{
          statement_date: Date.add(Date.utc_today(), -5),
          description: "IBG SETTLE #{System.unique_integer([:positive])}",
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

  defp pur_invoice_for(contact, amount, company, user) do
    good = good_fixture(company, user)
    pur_acct = Accounting.get_account_by_name("General Purchases", company, user)

    pur_tc =
      Repo.one!(
        from(tc in Accounting.TaxCode,
          where: tc.company_id == ^company.id and tc.code == "NoPTax"
        )
      )

    attrs =
      pur_invoice_attrs(contact, good, pur_acct, pur_tc,
        quantity: "1",
        unit_price: amount,
        tax_rate: "0"
      )

    {:ok, %{create_pur_invoice: pinv}} =
      FullCircle.Billing.create_pur_invoice(attrs, company, user)

    pinv
  end

  defp outstanding_rows(contact, company, user) do
    Accounting.query_transactions_for_matching(
      contact.id,
      Date.add(Date.utc_today(), -366) |> Date.to_iso8601(),
      Date.to_iso8601(Date.utc_today()),
      company,
      user
    )
  end

  defp matcher_from(row, amount) do
    %{
      "transaction_id" => row.transaction_id,
      "account_id" => row.account_id,
      "match_amount" => amount
    }
  end

  defp contact_attrs(contact) do
    %{"contact_id" => contact.id, "contact_name" => contact.name}
  end

  describe "create_settling_doc/6 :receipt" do
    test "creates an RC settling two invoices and matches the statement line", %{
      admin: admin,
      company: company,
      account: account,
      contact: contact
    } do
      invoice_for(contact, "100.00", company, admin)
      invoice_for(contact, "150.50", company, admin)
      line = import_line(account, company, %{amount: Decimal.new("250.50")})

      rows = outstanding_rows(contact, company, admin)
      assert length(rows) == 2

      matchers = Enum.map(rows, &matcher_from(&1, Decimal.to_string(Decimal.abs(&1.balance))))

      assert {:ok, receipt} =
               BankReconciliation.create_settling_doc(
                 :receipt,
                 [line.id],
                 contact_attrs(contact),
                 matchers,
                 company,
                 admin
               )

      assert receipt.receipt_no =~ "RC-"
      assert receipt.receipt_date == line.statement_date
      assert Decimal.eq?(receipt.funds_amount, Decimal.new("250.50"))

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
      assert Decimal.eq?(txn.amount, Decimal.new("250.50"))

      # the invoices are settled — no outstanding balance remains on them
      settled_ids = Enum.map(rows, & &1.transaction_id)

      assert outstanding_rows(contact, company, admin)
             |> Enum.filter(&(&1.transaction_id in settled_ids))
             |> Enum.all?(&Decimal.eq?(&1.balance, 0))
    end

    test "rejects when allocation does not equal the statement total", %{
      admin: admin,
      company: company,
      account: account,
      contact: contact
    } do
      invoice_for(contact, "250.50", company, admin)
      line = import_line(account, company, %{amount: Decimal.new("250.50")})
      [row] = outstanding_rows(contact, company, admin)

      assert {:error, :allocation_mismatch} =
               BankReconciliation.create_settling_doc(
                 :receipt,
                 [line.id],
                 contact_attrs(contact),
                 [matcher_from(row, "200.00")],
                 company,
                 admin
               )

      # nothing created, nothing matched
      assert Repo.get!(BankStatementLine, line.id).match_group_id == nil
      assert Repo.all(from(r in FullCircle.ReceiveFund.Receipt)) == []
    end

    test "rejects statement lines of the wrong sign", %{
      admin: admin,
      company: company,
      account: account,
      contact: contact
    } do
      line = import_line(account, company, %{amount: Decimal.new("-250.50")})

      assert {:error, :invalid_lines} =
               BankReconciliation.create_settling_doc(
                 :receipt,
                 [line.id],
                 contact_attrs(contact),
                 [],
                 company,
                 admin
               )
    end

    test "rejects an already matched statement line", %{
      admin: admin,
      company: company,
      account: account,
      contact: contact
    } do
      line = import_line(account, company, %{amount: Decimal.new("250.50")})
      BankReconciliation.dismiss_statement_lines([line.id])

      assert {:error, :invalid_lines} =
               BankReconciliation.create_settling_doc(
                 :receipt,
                 [line.id],
                 contact_attrs(contact),
                 [],
                 company,
                 admin
               )
    end
  end

  describe "match_with_difference/5" do
    defp insert_book_txn!(company, account, amount, date, particulars) do
      %Transaction{}
      |> Transaction.changeset(%{
        doc_type: "Receipt",
        doc_no: "RC#{System.unique_integer([:positive])}",
        doc_date: date,
        particulars: particulars,
        amount: amount,
        company_id: company.id,
        account_id: account.id
      })
      |> Repo.insert!()
    end

    defp fee_account(company, admin) do
      account_fixture(%{name: "Card Commission", account_type: "Expenses"}, company, admin)
    end

    test "posts the fee difference as a journal and matches all three", %{
      admin: admin,
      company: company,
      account: account
    } do
      # RC-100 issued a month before the recon; statement shows net 98.00
      txn =
        insert_book_txn!(
          company,
          account,
          Decimal.new("100.00"),
          Date.add(Date.utc_today(), -30),
          "VISA takings 15/6"
        )

      line =
        import_line(account, company, %{
          amount: Decimal.new("98.00"),
          statement_date: Date.add(Date.utc_today(), -29),
          description: "VISA SETTLEMENT NET"
        })

      fee_acct = fee_account(company, admin)

      assert {:ok, journal} =
               BankReconciliation.match_with_difference(
                 [line.id],
                 [txn.id],
                 fee_acct,
                 company,
                 admin
               )

      assert journal.journal_no =~ "JS-"

      line = Repo.get!(BankStatementLine, line.id)
      assert line.match_group_id

      group_txns =
        Repo.all(
          from(t in Transaction,
            where: t.match_group_id == ^line.match_group_id,
            order_by: t.amount
          )
        )

      assert length(group_txns) == 2
      assert Enum.all?(group_txns, & &1.reconciled)

      [fee_txn, receipt_txn] = group_txns
      assert receipt_txn.id == txn.id
      assert Decimal.eq?(fee_txn.amount, Decimal.new("-2.00"))
      assert fee_txn.account_id == account.id
      assert fee_txn.doc_date == line.statement_date

      # the expense side landed on the fee account
      expense_txn =
        Repo.one!(
          from(t in Transaction,
            where: t.account_id == ^fee_acct.id,
            where: t.doc_type == "Journal"
          )
        )

      assert Decimal.eq?(expense_txn.amount, Decimal.new("2.00"))
    end

    test "payment side: posts a cheque clearing fee and matches", %{
      admin: admin,
      company: company,
      account: account
    } do
      # PV-100 issued; bank cleared the cheque and charged 0.50 on top
      txn =
        %Transaction{}
        |> Transaction.changeset(%{
          doc_type: "Payment",
          doc_no: "PV#{System.unique_integer([:positive])}",
          doc_date: Date.add(Date.utc_today(), -20),
          particulars: "Cheque to supplier",
          amount: Decimal.new("-100.00"),
          company_id: company.id,
          account_id: account.id
        })
        |> Repo.insert!()

      line =
        import_line(account, company, %{
          amount: Decimal.new("-100.50"),
          statement_date: Date.add(Date.utc_today(), -18),
          description: "CHQ 123456 + CLEARING FEE"
        })

      fee_acct =
        account_fixture(%{name: "Bank Charges", account_type: "Expenses"}, company, admin)

      assert {:ok, journal} =
               BankReconciliation.match_with_difference(
                 [line.id],
                 [txn.id],
                 fee_acct,
                 company,
                 admin
               )

      line = Repo.get!(BankStatementLine, line.id)
      assert line.match_group_id

      group_txns =
        Repo.all(from(t in Transaction, where: t.match_group_id == ^line.match_group_id))

      assert length(group_txns) == 2
      assert Enum.all?(group_txns, & &1.reconciled)

      fee_txn = Enum.find(group_txns, &(&1.id != txn.id))
      assert Decimal.eq?(fee_txn.amount, Decimal.new("-0.50"))
      assert fee_txn.doc_date == line.statement_date

      expense_txn =
        Repo.one!(
          from(t in Transaction,
            where: t.account_id == ^fee_acct.id,
            where: t.doc_id == ^journal.id
          )
        )

      assert Decimal.eq?(expense_txn.amount, Decimal.new("0.50"))
    end

    test "rejects a selection with no difference", %{
      admin: admin,
      company: company,
      account: account
    } do
      txn =
        insert_book_txn!(company, account, Decimal.new("98.00"), Date.utc_today(), "EXACT")

      line = import_line(account, company, %{amount: Decimal.new("98.00")})

      assert {:error, :no_difference} =
               BankReconciliation.match_with_difference(
                 [line.id],
                 [txn.id],
                 fee_account(company, admin),
                 company,
                 admin
               )
    end

    test "rejects an already matched statement line", %{
      admin: admin,
      company: company,
      account: account
    } do
      txn =
        insert_book_txn!(company, account, Decimal.new("100.00"), Date.utc_today(), "MATCHED")

      line = import_line(account, company, %{amount: Decimal.new("98.00")})
      BankReconciliation.dismiss_statement_lines([line.id])

      assert {:error, :invalid_selection} =
               BankReconciliation.match_with_difference(
                 [line.id],
                 [txn.id],
                 fee_account(company, admin),
                 company,
                 admin
               )
    end
  end

  describe "create_settling_doc/6 :payment" do
    test "creates a PV settling a purchase invoice and matches the statement line", %{
      admin: admin,
      company: company,
      account: account,
      contact: contact
    } do
      pur_invoice_for(contact, "250.50", company, admin)
      line = import_line(account, company, %{amount: Decimal.new("-250.50")})

      [row] = rows = outstanding_rows(contact, company, admin)

      assert {:ok, payment} =
               BankReconciliation.create_settling_doc(
                 :payment,
                 [line.id],
                 contact_attrs(contact),
                 [matcher_from(row, Decimal.to_string(Decimal.abs(row.balance)))],
                 company,
                 admin
               )

      assert payment.payment_no =~ "PV-"
      assert Decimal.eq?(payment.funds_amount, Decimal.new("250.50"))

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

      settled_ids = Enum.map(rows, & &1.transaction_id)

      assert outstanding_rows(contact, company, admin)
             |> Enum.filter(&(&1.transaction_id in settled_ids))
             |> Enum.all?(&Decimal.eq?(&1.balance, 0))
    end
  end
end
