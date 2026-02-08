defmodule FullCircle.BillPayFixtures do
  alias FullCircle.{Repo, StdInterface, Accounting}
  alias FullCircle.Accounting.{Account, TaxCode}

  import FullCircle.BillingFixtures
  import Ecto.Query

  def pay_funds_account_fixture(company, user) do
    {:ok, account} =
      StdInterface.create(
        Account,
        "account",
        %{
          "name" => "Cash On Hand #{System.unique_integer([:positive])}",
          "account_type" => "Cash or Equivalent",
          "descriptions" => "Test cash account"
        },
        company,
        user
      )

    account
  end

  def payment_attrs(contact, good, purchase_account, purchase_tax_code, funds_account, opts \\ []) do
    pkg = List.first(good.packagings)
    qty = Keyword.get(opts, :quantity, "10")
    unit_price = Keyword.get(opts, :unit_price, "5.00")
    discount = Keyword.get(opts, :discount, "0")
    tax_rate = Keyword.get(opts, :tax_rate, Decimal.to_string(purchase_tax_code.rate))
    funds_amount = Keyword.get(opts, :funds_amount, "50.00")

    %{
      "payment_date" => Date.to_string(Date.utc_today()),
      "contact_name" => contact.name,
      "contact_id" => contact.id,
      "descriptions" => "Test payment",
      "funds_account_name" => funds_account.name,
      "funds_account_id" => funds_account.id,
      "funds_amount" => funds_amount,
      "payment_details" => %{
        "0" => %{
          "good_id" => good.id,
          "good_name" => good.name,
          "account_id" => purchase_account.id,
          "account_name" => purchase_account.name,
          "tax_code_id" => purchase_tax_code.id,
          "tax_code_name" => purchase_tax_code.code,
          "package_id" => pkg.id,
          "package_name" => pkg.name,
          "quantity" => qty,
          "unit_price" => unit_price,
          "discount" => discount,
          "tax_rate" => tax_rate,
          "unit_multiplier" => "0",
          "_persistent_id" => "1"
        }
      },
      "transaction_matchers" => %{}
    }
  end

  def payment_fixture(company, user, opts \\ []) do
    contact = contact_fixture(company, user)
    good = good_fixture(company, user)
    pur_acct = Accounting.get_account_by_name("General Purchases", company, user)
    funds_acct = pay_funds_account_fixture(company, user)

    pur_tc =
      if opts[:with_tax] do
        purchase_tax_code_fixture(company, user)
      else
        Repo.one!(
          from tc in TaxCode,
            where: tc.company_id == ^company.id and tc.code == "NoPTax"
        )
      end

    tax_rate = if opts[:with_tax], do: Decimal.to_string(pur_tc.rate), else: "0"

    attrs =
      payment_attrs(contact, good, pur_acct, pur_tc, funds_acct,
        Keyword.merge(opts, tax_rate: tax_rate)
      )

    {:ok, %{create_payment: payment}} =
      FullCircle.BillPay.create_payment(attrs, company, user)

    payment
  end
end
