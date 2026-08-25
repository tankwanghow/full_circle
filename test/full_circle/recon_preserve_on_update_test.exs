defmodule FullCircle.ReconPreserveOnUpdateTest do
  use FullCircle.DataCase

  alias FullCircle.{Accounting, BankReconciliation, BillPay, JournalEntry}
  alias FullCircle.Accounting.{TaxCode, Transaction}
  alias FullCircle.BankReconciliation.BankStatementLine

  import Ecto.Query
  import FullCircle.AccountingFixtures
  import FullCircle.BillingFixtures
  import FullCircle.BillPayFixtures

  setup do
    %{admin: admin, company: company} = billing_setup()
    bank = account_fixture(%{name: "Recon Bank", account_type: "Bank"}, company, admin)
    %{admin: admin, company: company, bank: bank}
  end

  defp matched_payment(company, admin, bank) do
    contact = contact_fixture(company, admin)
    good = good_fixture(company, admin)
    pur_acct = Accounting.get_account_by_name("General Purchases", company, admin)

    no_ptax =
      Repo.one!(from tc in TaxCode, where: tc.company_id == ^company.id and tc.code == "NoPTax")

    attrs = payment_attrs(contact, good, pur_acct, no_ptax, bank)
    {:ok, %{create_payment: payment}} = BillPay.create_payment(attrs, company, admin)

    txn = bank_txn(payment, bank)

    line_attrs = %{
      statement_date: Date.utc_today(),
      cheque_no: "111222",
      amount: Decimal.new("-50.00"),
      description: "CHQ 111222 CLEARED",
      reference: "ref-preserve"
    }

    {1, _} = BankReconciliation.import_statement(bank.id, company.id, [line_attrs], "pdf")

    line = Repo.one!(from sl in BankStatementLine, where: sl.account_id == ^bank.id)
    {:ok, _} = BankReconciliation.confirm_group_match([line.id], [txn.id])

    line = Repo.reload!(line)
    {payment, line, line.match_group_id}
  end

  defp bank_txn(payment, bank) do
    Repo.one!(
      from t in Transaction,
        where: t.doc_id == ^payment.id,
        where: t.doc_type == "Payment",
        where: t.account_id == ^bank.id
    )
  end

  defp payment_update_attrs(loaded, opts) do
    detail = List.first(loaded.payment_details)

    %{
      "payment_no" => loaded.payment_no,
      "payment_date" => Date.to_string(loaded.payment_date),
      "contact_name" => loaded.contact_name,
      "contact_id" => loaded.contact_id,
      "descriptions" => Keyword.get(opts, :descriptions, loaded.descriptions),
      "funds_account_name" => loaded.funds_account_name,
      "funds_account_id" => loaded.funds_account_id,
      "funds_amount" => Keyword.get(opts, :funds_amount, "50.00"),
      "payment_details" => %{
        "0" => %{
          "id" => detail.id,
          "good_id" => detail.good_id,
          "good_name" => detail.good_name,
          "account_id" => detail.account_id,
          "account_name" => detail.account_name,
          "tax_code_id" => detail.tax_code_id,
          "tax_code_name" => detail.tax_code_name,
          "package_id" => detail.package_id,
          "package_name" => detail.package_name,
          "quantity" => Keyword.get(opts, :quantity, "10"),
          "unit_price" => Keyword.get(opts, :unit_price, "5.00"),
          "discount" => "0",
          "tax_rate" => "0",
          "unit_multiplier" => "0",
          "_persistent_id" => "1"
        }
      },
      "transaction_matchers" => %{}
    }
  end

  describe "payment update with reconciled bank transaction" do
    test "an edit that keeps the bank amount preserves the match", %{
      admin: admin,
      company: company,
      bank: bank
    } do
      {payment, line, group_id} = matched_payment(company, admin, bank)
      loaded = BillPay.get_payment!(payment.id, company, admin)

      attrs = payment_update_attrs(loaded, descriptions: "edited descriptions only")

      assert {:ok, %{update_payment: updated}} =
               BillPay.update_payment(loaded, attrs, company, admin)

      new_txn = bank_txn(updated, bank)
      assert new_txn.reconciled
      assert new_txn.match_group_id == group_id
      assert Repo.reload!(line).match_group_id == group_id
    end

    test "an edit that changes the bank amount unmatches the whole group", %{
      admin: admin,
      company: company,
      bank: bank
    } do
      {payment, line, _group_id} = matched_payment(company, admin, bank)
      loaded = BillPay.get_payment!(payment.id, company, admin)

      attrs =
        payment_update_attrs(loaded,
          funds_amount: "100.00",
          quantity: "10",
          unit_price: "10.00"
        )

      assert {:ok, %{update_payment: updated}} =
               BillPay.update_payment(loaded, attrs, company, admin)

      new_txn = bank_txn(updated, bank)
      refute new_txn.reconciled
      assert is_nil(new_txn.match_group_id)
      assert is_nil(Repo.reload!(line).match_group_id)
    end
  end

  describe "journal update with reconciled bank transaction" do
    test "an in-place edit of other lines keeps the bank line matched", %{
      admin: admin,
      company: company,
      bank: bank
    } do
      sales = Accounting.get_account_by_name("General Sales", company, admin)

      attrs = %{
        "journal_date" => Date.to_iso8601(Date.utc_today()),
        "transactions" => %{
          "0" => %{
            "particulars" => "bank out",
            "amount" => "-75.00",
            "account_name" => bank.name,
            "account_id" => bank.id
          },
          "1" => %{
            "particulars" => "contra",
            "amount" => "75.00",
            "account_name" => sales.name,
            "account_id" => sales.id
          }
        }
      }

      {:ok, %{create_journal: journal}} = JournalEntry.create_journal(attrs, company, admin)

      txn =
        Repo.one!(
          from t in Transaction,
            where: t.doc_type == "Journal",
            where: t.doc_no == ^journal.journal_no,
            where: t.account_id == ^bank.id
        )

      line_attrs = %{
        statement_date: Date.utc_today(),
        cheque_no: "333444",
        amount: Decimal.new("-75.00"),
        description: "JOURNAL OUT",
        reference: "ref-journal"
      }

      {1, _} = BankReconciliation.import_statement(bank.id, company.id, [line_attrs], "pdf")
      line = Repo.one!(from sl in BankStatementLine, where: sl.account_id == ^bank.id)
      {:ok, _} = BankReconciliation.confirm_group_match([line.id], [txn.id])
      group_id = Repo.reload!(line).match_group_id

      loaded = JournalEntry.get_journal!(journal.id, company, admin)

      update_attrs = %{
        "journal_no" => loaded.journal_no,
        "journal_date" => Date.to_iso8601(loaded.journal_date),
        "transactions" =>
          loaded.transactions
          |> Enum.with_index()
          |> Enum.into(%{}, fn {t, idx} ->
            particulars = if t.account_id == bank.id, do: t.particulars, else: "contra edited"

            {Integer.to_string(idx),
             %{
               "id" => t.id,
               "particulars" => particulars,
               "amount" => Decimal.to_string(t.amount),
               "account_name" => t.account_name,
               "account_id" => t.account_id
             }}
          end)
      }

      assert {:ok, %{update_journal: _}} =
               JournalEntry.update_journal(loaded, update_attrs, company, admin)

      kept_txn = Repo.reload!(txn)
      assert kept_txn.reconciled
      assert kept_txn.match_group_id == group_id
      assert Repo.reload!(line).match_group_id == group_id
    end
  end
end
