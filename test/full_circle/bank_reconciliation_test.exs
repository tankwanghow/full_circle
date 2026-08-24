defmodule FullCircle.BankReconciliationTest do
  use FullCircle.DataCase

  alias FullCircle.Repo
  alias FullCircle.BankReconciliation
  alias FullCircle.BankReconciliation.BankStatementLine

  import FullCircle.SysFixtures
  import FullCircle.UserAccountsFixtures
  import FullCircle.AccountingFixtures

  setup do
    admin = user_fixture()
    company = company_fixture(admin, %{})
    account = account_fixture(%{name: "PBB Current", account_type: "Bank"}, company, admin)

    %{admin: admin, company: company, account: account}
  end

  defp import_line(account, company, attrs \\ %{}) do
    line =
      Map.merge(
        %{
          statement_date: ~D[2026-04-15],
          description: "IBG PAYMENT ABC SDN BHD",
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

  defp mark_matched(line_id) do
    Repo.get!(BankStatementLine, line_id)
    |> Ecto.Changeset.change(match_group_id: Ecto.UUID.generate())
    |> Repo.update!()
  end

  describe "update_statement_line/3" do
    test "corrects date, amount, description and cheque on an unmatched line", %{
      account: account,
      company: company
    } do
      line = import_line(account, company)

      assert {:ok, updated} =
               BankReconciliation.update_statement_line(line.id, company.id, %{
                 statement_date: ~D[2026-04-16],
                 description: "IBG PAYMENT ABC SDN BHD CORRECTED",
                 cheque_no: "654321",
                 amount: Decimal.new("-250.00")
               })

      assert updated.statement_date == ~D[2026-04-16]
      assert updated.description == "IBG PAYMENT ABC SDN BHD CORRECTED"
      assert updated.cheque_no == "654321"
      assert Decimal.eq?(updated.amount, Decimal.new("-250.00"))
    end

    test "rejects a matched line", %{account: account, company: company} do
      line = import_line(account, company)
      mark_matched(line.id)

      assert {:error, :matched} =
               BankReconciliation.update_statement_line(line.id, company.id, %{
                 amount: Decimal.new("-100.00")
               })
    end

    test "rejects a line from another company", %{account: account, company: company} do
      line = import_line(account, company)
      other = company_fixture(user_fixture(), %{})

      assert {:error, :not_found} =
               BankReconciliation.update_statement_line(line.id, other.id, %{
                 amount: Decimal.new("-100.00")
               })
    end

    test "rejects a zero amount", %{account: account, company: company} do
      line = import_line(account, company)

      assert {:error, changeset} =
               BankReconciliation.update_statement_line(line.id, company.id, %{
                 amount: Decimal.new("0")
               })

      assert "must not be zero" in errors_on(changeset).amount
    end
  end

  describe "delete_selected_statement_lines/2" do
    test "deletes unmatched selected lines", %{account: account, company: company} do
      a = import_line(account, company, %{description: "A", amount: Decimal.new("-10.00")})
      b = import_line(account, company, %{description: "B", amount: Decimal.new("-20.00")})
      keep = import_line(account, company, %{description: "KEEP", amount: Decimal.new("-30.00")})

      assert {:ok, 2} =
               BankReconciliation.delete_selected_statement_lines([a.id, b.id], company.id)

      remaining =
        BankReconciliation.list_statement_lines(
          account.id,
          company.id,
          ~D[2026-04-01],
          ~D[2026-04-30]
        )

      assert Enum.map(remaining, & &1.id) == [keep.id]
    end

    test "refuses when any selected line is matched", %{account: account, company: company} do
      a = import_line(account, company, %{description: "A", amount: Decimal.new("-10.00")})
      b = import_line(account, company, %{description: "B", amount: Decimal.new("-20.00")})
      mark_matched(a.id)

      assert {:error, :matched} =
               BankReconciliation.delete_selected_statement_lines([a.id, b.id], company.id)

      remaining =
        BankReconciliation.list_statement_lines(
          account.id,
          company.id,
          ~D[2026-04-01],
          ~D[2026-04-30]
        )

      assert length(remaining) == 2
    end

    test "rejects an empty selection", %{company: company} do
      assert {:error, :empty_selection} =
               BankReconciliation.delete_selected_statement_lines([], company.id)
    end
  end

  describe "find_doc_transaction/3" do
    test "finds the bank-account transaction for a Payment", %{
      admin: admin,
      company: company,
      account: account
    } do
      payment = payment_paid_from(account, company, admin)

      txn = BankReconciliation.find_doc_transaction(payment.id, account.id, "Payment")

      assert txn
      assert txn.doc_type == "Payment"
      assert txn.account_id == account.id
      assert Decimal.eq?(txn.amount, Decimal.new("-50.00"))
    end

    test "returns nil for another account", %{
      admin: admin,
      company: company,
      account: account
    } do
      other = account_fixture(%{name: "RHB Current", account_type: "Bank"}, company, admin)
      payment = payment_paid_from(account, company, admin)

      assert BankReconciliation.find_doc_transaction(payment.id, other.id, "Payment") == nil
    end
  end

  defp payment_paid_from(funds_account, company, user) do
    contact = FullCircle.BillingFixtures.contact_fixture(company, user)
    good = FullCircle.BillingFixtures.good_fixture(company, user)
    pur_acct = FullCircle.Accounting.get_account_by_name("General Purchases", company, user)

    pur_tc =
      Repo.one!(
        from(tc in FullCircle.Accounting.TaxCode,
          where: tc.company_id == ^company.id and tc.code == "NoPTax"
        )
      )

    attrs =
      FullCircle.BillPayFixtures.payment_attrs(
        contact,
        good,
        pur_acct,
        pur_tc,
        funds_account,
        tax_rate: "0"
      )

    {:ok, %{create_payment: payment}} = FullCircle.BillPay.create_payment(attrs, company, user)
    payment
  end
end
