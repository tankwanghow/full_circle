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

    test "price is line amount / quantity with signed discount applied", %{
      user: user,
      company: company
    } do
      contact = contact_fixture(company, user, %{"name" => "Disc Vendor"})
      good = good_fixture(company, user, %{"name" => "DiscGood"})

      create_pur_invoice(company, user, contact, good,
        quantity: "10",
        unit_price: "5.00",
        discount: "-10.00"
      )

      [row] = TaggedBill.goods_purchases_report("", "DiscGood", today(), today(), company.id)

      assert Decimal.equal?(row.amount, Decimal.new("40.00"))
      assert Decimal.equal?(row.price, Decimal.new("4.00"))
    end

    test "FOC line for the same good on one document is merged into the paid line", %{
      user: user,
      company: company
    } do
      contact = contact_fixture(company, user, %{"name" => "FOC Vendor"})
      good = good_fixture(company, user, %{"name" => "FocGood"})
      pur_acct = FullCircle.Accounting.get_account_by_name("General Purchases", company, user)

      pur_tc =
        Repo.one!(from tc in TaxCode, where: tc.company_id == ^company.id and tc.code == "NoPTax")

      attrs =
        pur_invoice_attrs(contact, good, pur_acct, pur_tc,
          quantity: "100",
          unit_price: "5.00",
          tax_rate: "0"
        )

      paid_line = attrs["pur_invoice_details"]["0"]

      foc_line =
        paid_line
        |> Map.merge(%{
          "quantity" => "10",
          "unit_price" => "0",
          "descriptions" => "FOC",
          "_persistent_id" => "2"
        })

      attrs = put_in(attrs, ["pur_invoice_details", "1"], foc_line)
      {:ok, _} = FullCircle.Billing.create_pur_invoice(attrs, company, user)

      [row] = TaggedBill.goods_purchases_report("", "FocGood", today(), today(), company.id)

      assert Decimal.equal?(row.qty, Decimal.new(110))
      assert Decimal.equal?(row.amount, Decimal.new("500.00"))
      assert Decimal.equal?(Decimal.round(row.price, 4), Decimal.new("4.5455"))
      assert row.descriptions =~ "FOC"
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

    test "price is quantity-weighted: sum(amount) / sum(qty)", %{
      user: user,
      company: company
    } do
      contact = contact_fixture(company, user, %{"name" => "Wgt Vendor"})
      good = good_fixture(company, user, %{"name" => "WgtGood"})

      # (90 * 1.00 - 5.00) + (10 * 10.00) = 185.00 over 100 units -> 1.85
      # an unweighted avg of line prices would give ~5.47
      create_pur_invoice(company, user, contact, good,
        quantity: "90",
        unit_price: "1.00",
        discount: "-5.00"
      )

      create_pur_invoice(company, user, contact, good, quantity: "10", unit_price: "10.00")

      [row] =
        TaggedBill.goods_purchases_summary_report("", "WgtGood", today(), today(), company.id)

      assert Decimal.equal?(row.qty, Decimal.new(100))
      assert Decimal.equal?(row.amount, Decimal.new("185.00"))
      assert Decimal.equal?(row.price, Decimal.new("1.85"))
    end
  end

  describe "custom ilike matching (match: :ilike)" do
    defp create_invoice_with_desc(company, user, contact, good, desc, opts) do
      sales_acct = FullCircle.Accounting.get_account_by_name("General Sales", company, user)

      sales_tc =
        Repo.one!(from tc in TaxCode, where: tc.company_id == ^company.id and tc.code == "NoSTax")

      attrs =
        invoice_attrs(contact, good, sales_acct, sales_tc, Keyword.put(opts, :tax_rate, "0"))
        |> put_in(["invoice_details", "0", "descriptions"], desc)

      {:ok, %{create_invoice: inv}} = FullCircle.Billing.create_invoice(attrs, company, user)
      inv
    end

    test "sales: name patterns OR description patterns, blank field ignored", %{
      user: user,
      company: company
    } do
      contact = contact_fixture(company, user, %{"name" => "Ilike Customer"})
      egg_good = good_fixture(company, user, %{"name" => "Grade A Egg"})
      misc_good = good_fixture(company, user, %{"name" => "Misc Item"})
      wheat_good = good_fixture(company, user, %{"name" => "Wheat Bran"})

      create_invoice_with_desc(company, user, contact, egg_good, nil, quantity: "1")

      create_invoice_with_desc(company, user, contact, misc_good, "used egg trays", quantity: "2")

      create_invoice_with_desc(company, user, contact, wheat_good, "plain wheat", quantity: "3")

      # egg good matches via name list, misc good via description list; wheat neither
      rows =
        TaggedBill.goods_sales_report("", "", today(), today(), company.id,
          match: :ilike,
          name_ilike: "%egg%, %maize%",
          desc_ilike: "%tray%"
        )

      goods = Enum.map(rows, & &1.good) |> Enum.sort()
      assert goods == ["Grade A Egg", "Misc Item"]
      assert Enum.any?(rows, &(&1.descriptions == "used egg trays"))

      # blank name list: only the description patterns apply
      rows =
        TaggedBill.goods_sales_report("", "", today(), today(), company.id,
          match: :ilike,
          name_ilike: "",
          desc_ilike: "%tray%"
        )

      assert Enum.map(rows, & &1.good) == ["Misc Item"]

      # summary honours the same patterns
      summaries =
        TaggedBill.goods_sales_summary_report("", "", today(), today(), company.id,
          match: :ilike,
          name_ilike: "%egg%",
          desc_ilike: ""
        )

      assert Enum.map(summaries, & &1.good) == ["Grade A Egg"]
    end

    test "purchases: name patterns OR description patterns", %{
      user: user,
      company: company
    } do
      contact = contact_fixture(company, user, %{"name" => "Ilike Vendor"})
      maize_good = good_fixture(company, user, %{"name" => "Maize Corn"})
      other_good = good_fixture(company, user, %{"name" => "Other Stuff"})

      pur_acct = FullCircle.Accounting.get_account_by_name("General Purchases", company, user)

      pur_tc =
        Repo.one!(from tc in TaxCode, where: tc.company_id == ^company.id and tc.code == "NoPTax")

      attrs =
        pur_invoice_attrs(contact, maize_good, pur_acct, pur_tc, quantity: "5", tax_rate: "0")

      {:ok, _} = FullCircle.Billing.create_pur_invoice(attrs, company, user)

      attrs2 =
        pur_invoice_attrs(contact, other_good, pur_acct, pur_tc, quantity: "7", tax_rate: "0")
        |> put_in(["pur_invoice_details", "0", "descriptions"], "maize transport charge")

      {:ok, _} = FullCircle.Billing.create_pur_invoice(attrs2, company, user)

      rows =
        TaggedBill.goods_purchases_report("", "", today(), today(), company.id,
          match: :ilike,
          name_ilike: "%maize%",
          desc_ilike: "%maize%"
        )

      goods = Enum.map(rows, & &1.good) |> Enum.sort()
      assert goods == ["Maize Corn", "Other Stuff"]
      assert Enum.any?(rows, &(&1.descriptions == "maize transport charge"))
    end

    test "exact mode is unchanged and rows still include descriptions", %{
      user: user,
      company: company
    } do
      contact = contact_fixture(company, user, %{"name" => "Exact Customer"})
      good = good_fixture(company, user, %{"name" => "ExactGood"})

      create_invoice_with_desc(company, user, contact, good, "line note", quantity: "1")

      [row] = TaggedBill.goods_sales_report("", "ExactGood", today(), today(), company.id)
      assert row.descriptions == "line note"

      # a partial name does not match in exact mode
      assert [] ==
               TaggedBill.goods_sales_report("", "Exact", today(), today(), company.id)
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
