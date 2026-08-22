defmodule FullCircle.TaggedBillTest do
  use FullCircle.DataCase, async: true

  import Ecto.Query
  import FullCircle.SysFixtures
  import FullCircle.UserAccountsFixtures
  import FullCircle.BillingFixtures
  import FullCircle.BillPayFixtures

  alias FullCircle.TaggedBill
  alias FullCircle.Accounting.TaxCode

  setup do
    user = user_fixture()
    company = company_fixture(user, %{})
    %{user: user, company: company}
  end

  defp today, do: Date.utc_today()

  defp create_pur_invoice(company, user, contact, good, opts) do
    pur_acct = FullCircle.Accounting.get_account_by_name("General Purchases", company, user)

    pur_tc =
      Repo.one!(from tc in TaxCode, where: tc.company_id == ^company.id and tc.code == "NoPTax")

    attrs =
      pur_invoice_attrs(contact, good, pur_acct, pur_tc, Keyword.put(opts, :tax_rate, "0"))

    {:ok, %{create_pur_invoice: pinv}} =
      FullCircle.Billing.create_pur_invoice(attrs, company, user)

    pinv
  end

  describe "goods_purchases_report/5" do
    test "lists PurInvoice and cash Payment lines with amounts", %{
      user: user,
      company: company
    } do
      contact = contact_fixture(company, user, %{"name" => "Purch Vendor A"})
      good = good_fixture(company, user, %{"name" => "PurchMaize"})

      pinv =
        create_pur_invoice(company, user, contact, good, quantity: "10", unit_price: "5.00")

      payment = payment_fixture(company, user, quantity: "4", unit_price: "2.50")

      rows = TaggedBill.goods_purchases_report("", "", today(), today(), company.id)

      pinv_row = Enum.find(rows, &(&1.doc_type == "PurInvoice"))
      pay_row = Enum.find(rows, &(&1.doc_type == "Payment"))

      assert pinv_row.doc_no == pinv.pur_invoice_no
      assert pinv_row.contact == "Purch Vendor A"
      assert pinv_row.good == "PurchMaize"
      assert Decimal.equal?(pinv_row.qty, Decimal.new(10))
      assert Decimal.equal?(pinv_row.amount, Decimal.new("50.00"))

      assert pay_row.doc_no == payment.payment_no
      assert Decimal.equal?(pay_row.qty, Decimal.new(4))
      assert Decimal.equal?(pay_row.amount, Decimal.new("10.00"))
    end

    test "filters by contact and goods list", %{user: user, company: company} do
      vendor_a = contact_fixture(company, user, %{"name" => "Filter Vendor A"})
      vendor_b = contact_fixture(company, user, %{"name" => "Filter Vendor B"})
      good_a = good_fixture(company, user, %{"name" => "FilterGoodA"})
      good_b = good_fixture(company, user, %{"name" => "FilterGoodB"})

      create_pur_invoice(company, user, vendor_a, good_a, quantity: "1", unit_price: "1")
      create_pur_invoice(company, user, vendor_b, good_b, quantity: "2", unit_price: "1")

      rows =
        TaggedBill.goods_purchases_report("Filter Vendor A", "", today(), today(), company.id)

      assert Enum.all?(rows, &(&1.contact == "Filter Vendor A"))
      assert Enum.any?(rows, &(&1.good == "FilterGoodA"))

      rows =
        TaggedBill.goods_purchases_report("", "FilterGoodB", today(), today(), company.id)

      assert Enum.any?(rows, &(&1.good == "FilterGoodB"))
      refute Enum.any?(rows, &(&1.good == "FilterGoodA"))
    end

    test "does not leak other companies' purchases", %{user: user, company: company} do
      other_user = user_fixture()
      other_company = company_fixture(other_user, %{})
      other_contact = contact_fixture(other_company, other_user, %{"name" => "Other Co Vendor"})
      other_good = good_fixture(other_company, other_user, %{"name" => "OtherCoGood"})

      create_pur_invoice(other_company, other_user, other_contact, other_good,
        quantity: "9",
        unit_price: "9"
      )

      rows = TaggedBill.goods_purchases_report("", "", today(), today(), company.id)
      assert rows == []
    end
  end

  describe "goods_purchases_summary_report/5" do
    test "sums quantities and amounts per good", %{user: user, company: company} do
      contact = contact_fixture(company, user, %{"name" => "Sum Vendor"})
      good = good_fixture(company, user, %{"name" => "SumGood"})

      create_pur_invoice(company, user, contact, good, quantity: "10", unit_price: "5.00")
      create_pur_invoice(company, user, contact, good, quantity: "6", unit_price: "5.00")

      [row] =
        TaggedBill.goods_purchases_summary_report("", "SumGood", today(), today(), company.id)

      assert row.good == "SumGood"
      assert Decimal.equal?(row.qty, Decimal.new(16))
      assert Decimal.equal?(row.amount, Decimal.new("80.00"))
    end
  end

  describe "goods_sales_report/5 tenant isolation" do
    test "does not leak other companies' sales", %{company: company} do
      other_user = user_fixture()
      other_company = company_fixture(other_user, %{})
      invoice_fixture(other_company, other_user)

      rows = TaggedBill.goods_sales_report("", "", today(), today(), company.id)
      assert rows == []
    end
  end
end
