defmodule FullCircle.DebCreFixtures do
  alias FullCircle.{Repo, Accounting}
  alias FullCircle.Accounting.TaxCode

  import FullCircle.BillingFixtures
  import Ecto.Query

  def credit_note_attrs(contact, account, tax_code, opts \\ []) do
    qty = Keyword.get(opts, :quantity, "10")
    unit_price = Keyword.get(opts, :unit_price, "5.00")
    tax_rate = Keyword.get(opts, :tax_rate, Decimal.to_string(tax_code.rate))

    %{
      "note_date" => Date.to_string(Date.utc_today()),
      "contact_name" => contact.name,
      "contact_id" => contact.id,
      "credit_note_details" => %{
        "0" => %{
          "descriptions" => "Test credit note line",
          "account_id" => account.id,
          "account_name" => account.name,
          "tax_code_id" => tax_code.id,
          "tax_code_name" => tax_code.code,
          "quantity" => qty,
          "unit_price" => unit_price,
          "tax_rate" => tax_rate,
          "_persistent_id" => "1"
        }
      },
      "transaction_matchers" => %{}
    }
  end

  def debit_note_attrs(contact, account, tax_code, opts \\ []) do
    qty = Keyword.get(opts, :quantity, "10")
    unit_price = Keyword.get(opts, :unit_price, "5.00")
    tax_rate = Keyword.get(opts, :tax_rate, Decimal.to_string(tax_code.rate))

    %{
      "note_date" => Date.to_string(Date.utc_today()),
      "contact_name" => contact.name,
      "contact_id" => contact.id,
      "debit_note_details" => %{
        "0" => %{
          "descriptions" => "Test debit note line",
          "account_id" => account.id,
          "account_name" => account.name,
          "tax_code_id" => tax_code.id,
          "tax_code_name" => tax_code.code,
          "quantity" => qty,
          "unit_price" => unit_price,
          "tax_rate" => tax_rate,
          "_persistent_id" => "1"
        }
      },
      "transaction_matchers" => %{}
    }
  end

  def credit_note_fixture(company, user, opts \\ []) do
    contact = contact_fixture(company, user)
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

    attrs =
      credit_note_attrs(contact, sales_acct, sales_tc,
        Keyword.merge(opts, tax_rate: tax_rate)
      )

    {:ok, %{create_credit_note: cn}} =
      FullCircle.DebCre.create_credit_note(attrs, company, user)

    cn
  end

  def debit_note_fixture(company, user, opts \\ []) do
    contact = contact_fixture(company, user)
    pur_acct = Accounting.get_account_by_name("General Purchases", company, user)

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
      debit_note_attrs(contact, pur_acct, pur_tc,
        Keyword.merge(opts, tax_rate: tax_rate)
      )

    {:ok, %{create_debit_note: dn}} =
      FullCircle.DebCre.create_debit_note(attrs, company, user)

    dn
  end
end
