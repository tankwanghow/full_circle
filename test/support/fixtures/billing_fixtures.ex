defmodule FullCircle.BillingFixtures do
  alias FullCircle.{StdInterface, Accounting, Repo}
  alias FullCircle.Accounting.{Contact, TaxCode}
  alias FullCircle.Product.Good

  import FullCircle.UserAccountsFixtures
  import FullCircle.SysFixtures
  import Ecto.Query

  def billing_setup do
    admin = user_fixture()
    company = company_fixture(admin, %{})
    %{admin: admin, company: company}
  end

  def contact_fixture(company, user, attrs \\ %{}) do
    defaults = %{
      "name" => "contact#{System.unique_integer([:positive])}",
      "reg_no" => "REG001",
      "tax_id" => "TAX001",
      "country" => "Malaysia"
    }

    {:ok, contact} =
      StdInterface.create(Contact, "contact", Map.merge(defaults, attrs), company, user)

    contact
  end

  def sales_tax_code_fixture(company, user, attrs \\ %{}) do
    sales_tax_acct = Accounting.get_account_by_name("Sales Tax Payable", company, user)

    defaults = %{
      "code" => "STax#{System.unique_integer([:positive])}",
      "rate" => "0.06",
      "tax_type" => "Sales",
      "account_name" => "Sales Tax Payable",
      "account_id" => sales_tax_acct.id
    }

    {:ok, tc} =
      StdInterface.create(TaxCode, "tax_code", Map.merge(defaults, attrs), company, user)

    tc
  end

  def purchase_tax_code_fixture(company, user, attrs \\ %{}) do
    pur_tax_acct = Accounting.get_account_by_name("Purchase Tax Receivable", company, user)

    defaults = %{
      "code" => "PTax#{System.unique_integer([:positive])}",
      "rate" => "0.06",
      "tax_type" => "Purchase",
      "account_name" => "Purchase Tax Receivable",
      "account_id" => pur_tax_acct.id
    }

    {:ok, tc} =
      StdInterface.create(TaxCode, "tax_code", Map.merge(defaults, attrs), company, user)

    tc
  end

  def good_fixture(company, user, attrs \\ %{}) do
    sales_acct = Accounting.get_account_by_name("General Sales", company, user)
    pur_acct = Accounting.get_account_by_name("General Purchases", company, user)

    no_stax =
      Repo.one!(
        from tc in TaxCode,
          where: tc.company_id == ^company.id and tc.code == "NoSTax"
      )

    no_ptax =
      Repo.one!(
        from tc in TaxCode,
          where: tc.company_id == ^company.id and tc.code == "NoPTax"
      )

    defaults = %{
      "name" => "good#{System.unique_integer([:positive])}",
      "unit" => "kg",
      "category" => "General",
      "sales_account_name" => sales_acct.name,
      "sales_account_id" => sales_acct.id,
      "purchase_account_name" => pur_acct.name,
      "purchase_account_id" => pur_acct.id,
      "sales_tax_code_name" => no_stax.code,
      "sales_tax_code_id" => no_stax.id,
      "purchase_tax_code_name" => no_ptax.code,
      "purchase_tax_code_id" => no_ptax.id,
      "packagings" => %{
        "0" => %{
          "name" => "default_pkg",
          "unit_multiplier" => "1",
          "cost_per_package" => "0",
          "default" => "true",
          "_persistent_id" => "1"
        }
      }
    }

    {:ok, good} =
      StdInterface.create(Good, "good", Map.merge(defaults, attrs), company, user)

    Repo.preload(good, :packagings)
  end

  def invoice_attrs(contact, good, sales_account, sales_tax_code, opts \\ []) do
    pkg = List.first(good.packagings)
    qty = Keyword.get(opts, :quantity, "10")
    unit_price = Keyword.get(opts, :unit_price, "5.00")
    discount = Keyword.get(opts, :discount, "0")
    tax_rate = Keyword.get(opts, :tax_rate, Decimal.to_string(sales_tax_code.rate))

    %{
      "invoice_date" => Date.to_string(Date.utc_today()),
      "due_date" => Date.to_string(Date.add(Date.utc_today(), 30)),
      "contact_name" => contact.name,
      "contact_id" => contact.id,
      "descriptions" => "Test invoice",
      "invoice_details" => %{
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
      }
    }
  end

  def pur_invoice_attrs(contact, good, purchase_account, purchase_tax_code, opts \\ []) do
    pkg = List.first(good.packagings)
    qty = Keyword.get(opts, :quantity, "10")
    unit_price = Keyword.get(opts, :unit_price, "5.00")
    discount = Keyword.get(opts, :discount, "0")
    tax_rate = Keyword.get(opts, :tax_rate, Decimal.to_string(purchase_tax_code.rate))

    %{
      "pur_invoice_date" => Date.to_string(Date.utc_today()),
      "due_date" => Date.to_string(Date.add(Date.utc_today(), 30)),
      "e_inv_internal_id" => "EINV#{System.unique_integer([:positive])}",
      "contact_name" => contact.name,
      "contact_id" => contact.id,
      "descriptions" => "Test purchase invoice",
      "pur_invoice_details" => %{
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
      }
    }
  end

  def invoice_fixture(company, user, opts \\ []) do
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
    attrs = invoice_attrs(contact, good, sales_acct, sales_tc, Keyword.put(opts, :tax_rate, tax_rate))

    {:ok, %{create_invoice: invoice}} =
      FullCircle.Billing.create_invoice(attrs, company, user)

    invoice
  end

  def pur_invoice_fixture(company, user, opts \\ []) do
    contact = contact_fixture(company, user)
    good = good_fixture(company, user)
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
    attrs = pur_invoice_attrs(contact, good, pur_acct, pur_tc, Keyword.put(opts, :tax_rate, tax_rate))

    {:ok, %{create_pur_invoice: pur_invoice}} =
      FullCircle.Billing.create_pur_invoice(attrs, company, user)

    pur_invoice
  end
end
