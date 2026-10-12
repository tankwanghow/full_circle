defmodule FullCircle.BankPaymentFixtures do
  alias FullCircle.{Accounting, BankPayment, BillPay, Repo, StdInterface}
  alias FullCircle.Accounting.{Account, TaxCode}

  import FullCircle.BillingFixtures
  import Ecto.Query

  def bank_gl_account_fixture(company, user) do
    {:ok, account} =
      StdInterface.create(
        Account,
        "account",
        %{
          "name" => "Bank #{System.unique_integer([:positive])}",
          "account_type" => "Bank",
          "descriptions" => "test bank"
        },
        company,
        user
      )

    account
  end

  def bank_contact_fixture(company, user, bank \\ %{}) do
    c =
      contact_fixture(company, user, %{
        "email" => "sup#{System.unique_integer([:positive])}@example.com"
      })

    attrs =
      Map.merge(
        %{
          "bank_code" => "MBBEMYKL",
          "bank_account_no" => "112233445566",
          "bank_account_name" => c.name
        },
        bank
      )

    {:ok, c} = Accounting.save_contact_bank(c, attrs, company, user)
    c
  end

  def install_template!(company, user, code) do
    {:ok, t} = BankPayment.load_template(code)

    {:ok, f} =
      BankPayment.save_format(
        %{
          "code" => t["code"],
          "name" => t["name"],
          "effective_from" => "2026-01-01",
          "spec" => t["spec"]
        },
        company,
        user
      )

    f
  end

  def profile_fixture(company, user, account, attrs \\ %{}) do
    defaults = %{
      "account_id" => account.id,
      "format_code" => "rhb_bulk_pay",
      "our_account_no" => "21234500012345",
      "start_date" => Date.to_iso8601(Date.add(BankPayment.today(company), -30)),
      "params" => %{"corporate_id" => "123456", "corporate_name" => "TEST SDN BHD"}
    }

    {:ok, p} =
      BankPayment.save_profile(%BankPayment.Profile{}, Map.merge(defaults, attrs), company, user)

    p
  end

  def payment_attrs_for(company, user, contact, funds_account, amount) do
    good = good_fixture(company, user)
    pur = Accounting.get_account_by_name("General Purchases", company, user)

    no_ptax =
      Repo.one!(from tc in TaxCode, where: tc.company_id == ^company.id and tc.code == "NoPTax")

    FullCircle.BillPayFixtures.payment_attrs(contact, good, pur, no_ptax, funds_account,
      funds_amount: amount,
      quantity: "1",
      unit_price: amount,
      tax_rate: "0"
    )
  end

  def bank_payment_fixture(company, user, contact, funds_account, amount \\ "100.00") do
    attrs = payment_attrs_for(company, user, contact, funds_account, amount)
    {:ok, %{create_payment: p}} = BillPay.create_payment(attrs, company, user)
    p
  end

  @doc "A PB Payment Status Feedback file (ECP guide §7) for `rows` of {record_id, cents, status, reason}."
  def psf_text(uploaded_filename, rows) do
    header =
      String.pad_trailing("H" <> "20261013" <> String.pad_trailing(uploaded_filename, 23), 365)

    details =
      for {rec, cents, status, reason} <- rows do
        "D" <>
          String.pad_trailing(rec, 16) <>
          String.duplicate(" ", 183) <>
          String.pad_leading("#{cents}", 18, "0") <>
          String.duplicate(" ", 40) <>
          status <>
          String.pad_trailing(reason, 40)
      end

    Enum.join([header | details] ++ ["F" <> String.duplicate("0", 50)], "\r\n") <> "\r\n"
  end
end
