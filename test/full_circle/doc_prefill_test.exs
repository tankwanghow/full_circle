defmodule FullCircle.DocPrefillTest do
  use FullCircle.DataCase, async: true

  import FullCircle.BillingFixtures
  import Ecto.Query

  alias FullCircle.{Accounting, Billing, DocPrefill, Repo}
  alias FullCircle.Accounting.TaxCode

  setup do
    %{admin: admin, company: company} = billing_setup()
    %{admin: admin, company: company}
  end

  defp bought(contact, good, company, admin) do
    pur_acct = Accounting.get_account_by_name("General Purchases", company, admin)

    no_ptax =
      Repo.one!(from tc in TaxCode, where: tc.company_id == ^company.id and tc.code == "NoPTax")

    {:ok, _} =
      Billing.create_pur_invoice(
        pur_invoice_attrs(contact, good, pur_acct, no_ptax, tax_rate: "0"),
        company,
        admin
      )
  end

  defp line(descr, qty, tax \\ nil),
    do: %{descriptions: descr, quantity: qty, unit_price: 1, discount: 0, tax_rate: tax}

  describe "seed_lines/1" do
    test "percent becomes a fraction; multiplier and package qty stay 0" do
      [line] =
        DocPrefill.seed_lines([
          %{
            descriptions: "PVC PIPE",
            quantity: 4.0,
            unit_price: 12.5,
            discount: 0.0,
            tax_rate: 6.0
          }
        ])

      assert line["descriptions"] == "PVC PIPE"
      assert line["quantity"] == 4.0
      assert line["tax_rate"] == 0.06
      assert line["unit_multiplier"] == 0
      assert line["package_qty"] == 0
      assert line["_persistent_id"] == 0
      assert line["good_name"] == ""
    end

    test "Decimal percent becomes a Decimal fraction; nil tax is 0" do
      [a, b] =
        DocPrefill.seed_lines([
          line("A", Decimal.new(1), Decimal.new("8")),
          line("B", Decimal.new(1))
        ])

      assert Decimal.eq?(a["tax_rate"], Decimal.new("0.08"))
      assert b["tax_rate"] == 0
      assert b["_persistent_id"] == 1
    end
  end

  describe "put_contact/7" do
    test "TIN match: contact set, no warning", %{company: c, admin: u} do
      contact =
        contact_fixture(c, u, %{"name" => "Kedai Ali Hardware", "tax_id" => "C2345678901"})

      {attrs, warning} =
        DocPrefill.put_contact(%{}, "C2345678901", nil, "whatever", c, :supplier)

      assert attrs.contact_id == contact.id
      assert attrs.contact_name == contact.name
      assert warning == nil
    end

    test "name-only match warns and names the source", %{company: c, admin: u} do
      contact_fixture(c, u, %{"name" => "Kedai Ali Hardware", "tax_id" => "C1", "reg_no" => "R1"})

      {attrs, warning} =
        DocPrefill.put_contact(%{}, nil, nil, "KEDAI ALI HARDWARE", c, :supplier,
          source: "Receipt"
        )

      assert attrs.contact_id
      assert warning =~ "matched by name only"
      assert warning =~ "Receipt"
    end

    test "no match: contact blank with the read name, warns", %{company: c} do
      {attrs, warning} =
        DocPrefill.put_contact(%{}, "C999", nil, "Nobody Sdn Bhd", c, :supplier)

      assert attrs.contact_id == nil
      assert attrs.contact_name == "Nobody Sdn Bhd"
      assert warning =~ "not found"
    end
  end

  describe "put_goods/5" do
    test "sole good: good and packaging seeded, multiplier 0, package_qty = qty",
         %{company: c, admin: u} do
      contact = contact_fixture(c, u)
      good = good_fixture(c, u)
      bought(contact, good, c, u)

      attrs =
        %{contact_id: contact.id, payment_details: DocPrefill.seed_lines([line("x", 3)])}
        |> DocPrefill.put_goods(:payment_details, c, u, :purchase)

      [seeded] = attrs.payment_details
      assert seeded["good_name"] == good.name
      assert seeded["package_name"] == "default_pkg"
      assert seeded["unit_multiplier"] == 0
      assert seeded["package_qty"] == 3
    end

    test "two goods: only a good named in the description, without packaging",
         %{company: c, admin: u} do
      contact = contact_fixture(c, u)
      g1 = good_fixture(c, u, %{"name" => "Layer Feed"})
      g2 = good_fixture(c, u, %{"name" => "Wheat Pollard"})
      bought(contact, g1, c, u)
      bought(contact, g2, c, u)

      attrs =
        %{
          contact_id: contact.id,
          pur_invoice_details:
            DocPrefill.seed_lines([line("WHEAT POLLARD 55KG", 2), line("GLUE", 1)])
        }
        |> DocPrefill.put_goods(:pur_invoice_details, c, u, :purchase)

      [pollard, glue] = attrs.pur_invoice_details
      assert pollard["good_name"] == g2.name
      assert pollard["package_name"] == ""
      assert glue["good_name"] == ""
    end

    test "no contact: unchanged", %{company: c, admin: u} do
      attrs = %{contact_id: nil, payment_details: []}
      assert DocPrefill.put_goods(attrs, :payment_details, c, u, :purchase) == attrs
    end
  end

  test "to_decimal/1 parses strings, numbers and junk" do
    assert Decimal.eq?(DocPrefill.to_decimal("12.50"), Decimal.new("12.50"))
    assert Decimal.eq?(DocPrefill.to_decimal(3), Decimal.new(3))
    assert DocPrefill.to_decimal("abc") == nil
    assert DocPrefill.to_decimal(nil) == nil
  end
end
