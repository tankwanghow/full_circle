defmodule FullCircle.Receipts.PrefillTest do
  use FullCircle.DataCase, async: true

  import FullCircle.BillingFixtures
  import FullCircle.BillPayFixtures
  import FullCircle.AccountingFixtures
  import Ecto.Query

  alias FullCircle.{Accounting, Billing, BillPay, Repo, Sys}
  alias FullCircle.Accounting.TaxCode
  alias FullCircle.Receipts.{Extracted, Prefill}

  setup do
    %{admin: u, company: c} = billing_setup()
    %{u: u, c: c}
  end

  defp ex(attrs \\ %{}) do
    struct!(
      %Extracted{
        supplier_name: "Kedai Ali Hardware",
        supplier_tin: "C2345678901",
        doc_no: "A12345",
        date: Date.utc_today(),
        payment_method: "cash",
        total: Decimal.new("54.00"),
        tax_total: nil,
        rounding: nil,
        lines: [
          %{
            descriptions: "PVC PIPE",
            quantity: Decimal.new(4),
            unit_price: Decimal.new("12.50"),
            discount: Decimal.new(0),
            tax_rate: nil,
            amount: Decimal.new("50.00")
          },
          %{
            descriptions: "GLUE",
            quantity: Decimal.new(1),
            unit_price: Decimal.new("4.00"),
            discount: Decimal.new(0),
            tax_rate: Decimal.new("8"),
            amount: Decimal.new("4.00")
          }
        ]
      },
      attrs
    )
  end

  defp no_ptax(c),
    do: Repo.one!(from tc in TaxCode, where: tc.company_id == ^c.id and tc.code == "NoPTax")

  test "payment header: date, funds amount, shop + doc no in descriptions", %{c: c, u: u} do
    seed = Prefill.build(ex(), c, u, :payment_details)
    assert seed.attrs.payment_date == Date.utc_today()
    assert Decimal.eq?(seed.attrs.funds_amount, Decimal.new("54.00"))
    assert seed.attrs.descriptions == "Kedai Ali Hardware #A12345"
    assert length(seed.attrs.payment_details) == 2
    assert seed.contact_ids == {"C2345678901", nil}
  end

  test "pur invoice header: supplier bill no into e_inv_internal_id, never pur_invoice_no", %{
    c: c,
    u: u
  } do
    seed = Prefill.build(ex(), c, u, :pur_invoice_details)
    assert seed.attrs.e_inv_internal_id == "A12345"
    refute Map.has_key?(seed.attrs, :pur_invoice_no)
    assert seed.attrs.pur_invoice_date == Date.utc_today()
    assert seed.attrs.due_date == Date.utc_today()
  end

  test "lines: percent tax becomes a fraction, multiplier 0", %{c: c, u: u} do
    [_pipe, glue] = Prefill.build(ex(), c, u, :payment_details).attrs.payment_details
    assert Decimal.eq?(glue["tax_rate"], Decimal.new("0.08"))
    assert glue["unit_multiplier"] == 0
  end

  test "contact by TIN, no contact warning", %{c: c, u: u} do
    contact = contact_fixture(c, u, %{"name" => "Kedai Ali Hdw", "tax_id" => "C2345678901"})
    seed = Prefill.build(ex(), c, u, :payment_details)
    assert seed.attrs.contact_id == contact.id
    refute Enum.any?(seed.warnings, &(&1 =~ "Supplier"))
  end

  test "unknown supplier: blank contact with a warning", %{c: c, u: u} do
    seed = Prefill.build(ex(), c, u, :payment_details)
    assert seed.attrs.contact_id == nil
    assert Enum.any?(seed.warnings, &(&1 =~ "not found"))
  end

  test "SST printed only as a total becomes its own line; rounding too", %{c: c, u: u} do
    lines = [hd(ex().lines)]

    seed =
      Prefill.build(
        ex(%{
          lines: lines,
          tax_total: Decimal.new("4.00"),
          rounding: Decimal.new("-0.02"),
          total: Decimal.new("53.98")
        }),
        c,
        u,
        :payment_details
      )

    descrs = Enum.map(seed.attrs.payment_details, & &1["descriptions"])
    assert descrs == ["PVC PIPE", "SST", "Rounding adj."]
    [_, sst, rnd] = seed.attrs.payment_details
    assert Decimal.eq?(sst["unit_price"], Decimal.new("4.00"))
    assert sst["good_name"] == ""
    assert Decimal.eq?(rnd["unit_price"], Decimal.new("-0.02"))
  end

  test "no SST line when a line already carries a tax rate", %{c: c, u: u} do
    seed = Prefill.build(ex(%{tax_total: Decimal.new("0.32")}), c, u, :payment_details)
    refute Enum.any?(seed.attrs.payment_details, &(&1["descriptions"] == "SST"))
  end

  test "funds account: sole account first, then Cash In Hand for cash, else none", %{c: c, u: u} do
    cash = account_fixture(%{name: "Cash In Hand", account_type: "Cash or Equivalent"}, c, u)

    seed = Prefill.build(ex(), c, u, :payment_details)
    assert seed.attrs.funds_account_id == cash.id

    seed = Prefill.build(ex(%{payment_method: "card"}), c, u, :payment_details)
    refute Map.get(seed.attrs, :funds_account_id)

    contact = contact_fixture(c, u, %{"tax_id" => "C2345678901"})
    bank = pay_funds_account_fixture(c, u)
    good = good_fixture(c, u)
    pur_acct = Accounting.get_account_by_name("General Purchases", c, u)

    {:ok, _} =
      BillPay.create_payment(
        payment_attrs(contact, good, pur_acct, no_ptax(c), bank, tax_rate: "0"),
        c,
        u
      )

    seed = Prefill.build(ex(), c, u, :payment_details)
    assert seed.attrs.funds_account_id == bank.id
  end

  test "possible duplicate pur invoice: same contact and supplier bill no", %{c: c, u: u} do
    contact = contact_fixture(c, u, %{"tax_id" => "C2345678901"})
    good = good_fixture(c, u)
    pur_acct = Accounting.get_account_by_name("General Purchases", c, u)

    attrs =
      pur_invoice_attrs(contact, good, pur_acct, no_ptax(c), tax_rate: "0")
      |> Map.put("e_inv_internal_id", "A12345")

    {:ok, %{create_pur_invoice: pinv}} = Billing.create_pur_invoice(attrs, c, u)

    seed = Prefill.build(ex(), c, u, :pur_invoice_details)
    assert Enum.any?(seed.warnings, &(&1 =~ "Possible duplicate" and &1 =~ pinv.pur_invoice_no))
  end

  test "possible duplicate payment: same contact, date and amount", %{c: c, u: u} do
    contact = contact_fixture(c, u, %{"tax_id" => "C2345678901"})
    bank = pay_funds_account_fixture(c, u)
    good = good_fixture(c, u)
    pur_acct = Accounting.get_account_by_name("General Purchases", c, u)

    {:ok, %{create_payment: pv}} =
      BillPay.create_payment(
        payment_attrs(contact, good, pur_acct, no_ptax(c), bank,
          tax_rate: "0",
          quantity: "1",
          unit_price: "54.00",
          funds_amount: "54.00"
        ),
        c,
        u
      )

    seed = Prefill.build(ex(), c, u, :payment_details)
    assert Enum.any?(seed.warnings, &(&1 =~ "Possible duplicate" and &1 =~ pv.payment_no))

    assert Prefill.duplicate_warning(
             %{
               "contact_id" => contact.id,
               "payment_date" => Date.to_iso8601(Date.utc_today()),
               "funds_amount" => "54.00"
             },
             :payment_details,
             c
           )

    refute Prefill.duplicate_warning(
             %{"contact_id" => nil, "payment_date" => "", "funds_amount" => ""},
             :payment_details,
             c
           )
  end

  test "date in a closed period warns", %{c: c, u: u} do
    yesterday = Date.add(Date.utc_today(), -1)
    {:ok, _} = Sys.close_period_through(c, yesterday, u)
    seed = Prefill.build(ex(%{date: Date.add(yesterday, -3)}), c, u, :payment_details)
    assert Enum.any?(seed.warnings, &(&1 =~ "closed accounting period"))
  end

  test "printed e-invoice uuid that we have synced warns", %{c: c, u: u} do
    Repo.insert_all("e_invoices", [%{uuid: "ABC123UUID", company_id: Ecto.UUID.dump!(c.id)}])
    seed = Prefill.build(ex(%{e_invoice_uuid: "ABC123UUID"}), c, u, :pur_invoice_details)
    assert Enum.any?(seed.warnings, &(&1 =~ "has an e-invoice"))
  end

  test "not recognised: only descriptions from the summary", %{c: c, u: u} do
    seed =
      Prefill.build(
        %Extracted{
          recognized: false,
          summary: "Photo of a cheque",
          warnings: ["Not recognised as a bill or receipt."]
        },
        c,
        u,
        :payment_details
      )

    assert seed.attrs == %{descriptions: "Photo of a cheque"}
    assert seed.warnings == ["Not recognised as a bill or receipt."]
    assert seed.total == nil
  end
end
