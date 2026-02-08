defmodule FullCircle.ReceiveFundFixtures do
  alias FullCircle.{Repo, StdInterface, Accounting}
  alias FullCircle.Accounting.{Account, TaxCode}

  import FullCircle.BillingFixtures
  import Ecto.Query

  def funds_account_fixture(company, user) do
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

  def receipt_attrs(contact, good, sales_account, sales_tax_code, opts \\ []) do
    pkg = List.first(good.packagings)
    qty = Keyword.get(opts, :quantity, "10")
    unit_price = Keyword.get(opts, :unit_price, "5.00")
    discount = Keyword.get(opts, :discount, "0")
    tax_rate = Keyword.get(opts, :tax_rate, Decimal.to_string(sales_tax_code.rate))
    funds_amount = Keyword.get(opts, :funds_amount, "0")
    funds_account_name = Keyword.get(opts, :funds_account_name, "")
    funds_account_id = Keyword.get(opts, :funds_account_id, nil)

    attrs = %{
      "receipt_date" => Date.to_string(Date.utc_today()),
      "contact_name" => contact.name,
      "contact_id" => contact.id,
      "descriptions" => "Test receipt",
      "funds_amount" => funds_amount,
      "receipt_details" => %{
        "0" => %{
          "good_id" => good.id,
          "good_name" => good.name,
          "account_id" => sales_account.id,
          "account_name" => sales_account.name,
          "tax_code_id" => sales_tax_code.id,
          "tax_code_name" => sales_tax_code.code,
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
      "received_cheques" => %{},
      "transaction_matchers" => %{}
    }

    if funds_amount != "0" do
      Map.merge(attrs, %{
        "funds_account_name" => funds_account_name,
        "funds_account_id" => funds_account_id
      })
    else
      attrs
    end
  end

  def receipt_attrs_with_funds(contact, good, sales_account, sales_tax_code, funds_account, opts \\ []) do
    receipt_attrs(contact, good, sales_account, sales_tax_code,
      Keyword.merge(opts,
        funds_amount: Keyword.get(opts, :funds_amount, "50.00"),
        funds_account_name: funds_account.name,
        funds_account_id: funds_account.id
      )
    )
  end

  def receipt_attrs_with_cheque(contact, good, sales_account, sales_tax_code, opts \\ []) do
    base = receipt_attrs(contact, good, sales_account, sales_tax_code, opts)

    Map.put(base, "received_cheques", %{
      "0" => %{
        "bank" => "Test Bank",
        "due_date" => Date.to_string(Date.utc_today()),
        "state" => "Selangor",
        "city" => "KL",
        "cheque_no" => "CHQ001",
        "amount" => Keyword.get(opts, :cheque_amount, "50.00"),
        "_persistent_id" => "1"
      }
    })
  end

  def receipt_fixture(company, user, opts \\ []) do
    contact = contact_fixture(company, user)
    good = good_fixture(company, user)
    sales_acct = Accounting.get_account_by_name("General Sales", company, user)

    sales_tc =
      if opts[:with_tax] do
        sales_tax_code_fixture(company, user)
      else
        Repo.one!(
          from tc in TaxCode,
            where: tc.company_id == ^company.id and tc.code == "NoSTax"
        )
      end

    tax_rate = if opts[:with_tax], do: Decimal.to_string(sales_tc.rate), else: "0"

    funds_acct = funds_account_fixture(company, user)

    attrs =
      receipt_attrs_with_funds(contact, good, sales_acct, sales_tc, funds_acct,
        Keyword.merge(opts, tax_rate: tax_rate)
      )

    {:ok, %{create_receipt: receipt}} =
      FullCircle.ReceiveFund.create_receipt(attrs, company, user)

    receipt
  end
end
