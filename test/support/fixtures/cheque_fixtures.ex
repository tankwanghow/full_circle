defmodule FullCircle.ChequeFixtures do
  alias FullCircle.{StdInterface, Accounting}
  alias FullCircle.Accounting.Account

  import FullCircle.BillingFixtures
  import FullCircle.ReceiveFundFixtures
  import Ecto.Query

  def bank_account_fixture(company, user) do
    {:ok, account} =
      StdInterface.create(
        Account,
        "account",
        %{
          "name" => "Bank Account #{System.unique_integer([:positive])}",
          "account_type" => "Bank",
          "descriptions" => "Test bank account"
        },
        company,
        user
      )

    account
  end

  def deposit_fixture(company, user, opts \\ []) do
    bank_acct = bank_account_fixture(company, user)
    funds_from_acct = funds_account_fixture(company, user)
    funds_amount = Keyword.get(opts, :funds_amount, "100.00")

    attrs = %{
      "deposit_date" => Date.to_string(Date.utc_today()),
      "bank_name" => bank_acct.name,
      "bank_id" => bank_acct.id,
      "funds_from_name" => funds_from_acct.name,
      "funds_from_id" => funds_from_acct.id,
      "funds_amount" => funds_amount,
      "descriptions" => "Test deposit"
    }

    {:ok, %{create_deposit: deposit}} =
      FullCircle.Cheque.create_deposit(attrs, company, user)

    deposit
  end

  def return_cheque_fixture(company, user) do
    # First create a receipt with a cheque
    contact = contact_fixture(company, user)
    good = good_fixture(company, user)
    sales_acct = Accounting.get_account_by_name("General Sales", company, user)

    no_stax =
      FullCircle.Repo.one!(
        from tc in FullCircle.Accounting.TaxCode,
          where: tc.company_id == ^company.id and tc.code == "NoSTax"
      )

    attrs =
      receipt_attrs_with_cheque(contact, good, sales_acct, no_stax,
        quantity: "10",
        unit_price: "5.00",
        cheque_amount: "50.00"
      )

    {:ok, %{create_receipt: receipt}} =
      FullCircle.ReceiveFund.create_receipt(attrs, company, user)

    receipt = FullCircle.Repo.preload(receipt, :received_cheques)
    cheque = List.first(receipt.received_cheques)

    return_attrs = %{
      "return_date" => Date.to_string(Date.utc_today()),
      "return_reason" => "Bounced",
      "cheque_owner_name" => contact.name,
      "cheque_owner_id" => contact.id,
      "cheque_no" => cheque.cheque_no,
      "cheque_due_date" => Date.to_string(cheque.due_date),
      "cheque_amount" => Decimal.to_string(cheque.amount),
      "cheque" => %{"id" => cheque.id}
    }

    {:ok, %{create_return_cheque: return_cheque}} =
      FullCircle.Cheque.create_return_cheque(return_attrs, company, user)

    return_cheque
  end
end
