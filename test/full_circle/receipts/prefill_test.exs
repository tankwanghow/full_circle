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
    assert seed.duplicate =~ "Possible duplicate"
    assert seed.duplicate =~ pinv.pur_invoice_no
    refute Enum.any?(seed.warnings, &(&1 =~ "Possible duplicate"))
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
    assert seed.duplicate =~ pv.payment_no

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

  test "learn only from an identifier match: {contact, tin, brn}", %{c: c, u: u} do
    contact = contact_fixture(c, u, %{"name" => "Kedai Ali Hdw", "tax_id" => "C2345678901"})
    seed = Prefill.build(ex(%{supplier_brn: "201901012345"}), c, u, :payment_details)
    assert seed.learn == {contact.id, "C2345678901", "201901012345"}

    contact_fixture(c, u, %{"name" => "Kedai Ali Hardware", "tax_id" => "OTHER"})
    seed = Prefill.build(ex(%{supplier_tin: nil}), c, u, :payment_details)
    assert seed.attrs.contact_id
    assert seed.learn == nil
  end

  describe "build/4 with a list" do
    defp fuel(shop, no, days_ago, total, method \\ "cash") do
      ex(%{
        supplier_name: shop,
        supplier_tin: nil,
        doc_no: no,
        date: Date.add(Date.utc_today(), -days_ago),
        total: Decimal.new(total),
        payment_method: method,
        lines: []
      })
    end

    defp dmy(days_ago), do: Calendar.strftime(Date.add(Date.utc_today(), -days_ago), "%d/%m/%Y")

    test "one recognised document seeds exactly like the struct clause", %{c: c, u: u} do
      assert Prefill.build([ex()], c, u, :payment_details) ==
               Prefill.build(ex(), c, u, :payment_details)
    end

    test "3 receipts, 3 shops: no payee, one dated line each, sum, latest date", %{c: c, u: u} do
      contact_fixture(c, u, %{"name" => "Petronas BM", "tax_id" => "C2345678901"})

      docs = [
        fuel("Shell Juru", "S-9", 2, "60.00"),
        fuel("Petronas BM", "P-101", 9, "80.00"),
        fuel("Caltex Alma", "C-7", 5, "45.50")
      ]

      seed = Prefill.build(docs, c, u, :payment_details)

      refute Map.has_key?(seed.attrs, :contact_id)
      refute Map.has_key?(seed.attrs, :contact_name)
      assert seed.learn == nil
      assert seed.contact_ids == {nil, nil}
      assert seed.duplicate == nil

      assert Enum.map(seed.attrs.payment_details, & &1["descriptions"]) == [
               "Petronas BM #P-101 #{dmy(9)}",
               "Caltex Alma #C-7 #{dmy(5)}",
               "Shell Juru #S-9 #{dmy(2)}"
             ]

      [first | _] = seed.attrs.payment_details
      assert Decimal.eq?(first["quantity"], 1)
      assert Decimal.eq?(first["unit_price"], Decimal.new("80.00"))
      assert first["good_name"] == ""

      assert Decimal.eq?(seed.attrs.funds_amount, Decimal.new("185.50"))
      assert Decimal.eq?(seed.total, Decimal.new("185.50"))
      assert seed.attrs.payment_date == Date.add(Date.utc_today(), -2)
      assert seed.attrs.descriptions == "3 receipts: Shell Juru, Petronas BM, Caltex Alma"

      assert "3 receipts from 3 shops — pick the payee (e.g. the salesperson)." in seed.warnings

      assert "Receipts are dated #{dmy(9)} to #{dmy(2)}; the pay date was set to #{dmy(2)}." in seed.warnings
    end

    test "receipts from one shop still leave the payee blank", %{c: c, u: u} do
      contact_fixture(c, u, %{"name" => "Petronas BM", "tax_id" => "C2345678901"})

      docs = [
        %{fuel("Petronas BM", "P-1", 3, "50.00") | supplier_tin: "C2345678901"},
        %{fuel("Petronas BM", "P-2", 1, "70.00") | supplier_tin: "C2345678901"}
      ]

      seed = Prefill.build(docs, c, u, :payment_details)
      refute Map.has_key?(seed.attrs, :contact_id)
      assert "2 receipts from 1 shop — pick the payee (e.g. the salesperson)." in seed.warnings
    end

    test "all cash → Cash In Hand; any other method → no funds account", %{c: c, u: u} do
      cash = account_fixture(%{name: "Cash In Hand", account_type: "Cash or Equivalent"}, c, u)

      seed =
        Prefill.build([fuel("A", "1", 1, "10"), fuel("B", "2", 1, "20")], c, u, :payment_details)

      assert seed.attrs.funds_account_id == cash.id

      seed =
        Prefill.build(
          [fuel("A", "1", 1, "10"), fuel("B", "2", 1, "20", "card")],
          c,
          u,
          :payment_details
        )

      refute Map.has_key?(seed.attrs, :funds_account_id)
    end

    test "unrecognised entries are dropped with a warning", %{c: c, u: u} do
      junk = %Extracted{recognized: false, summary: "A coffee cup", warnings: []}

      seed =
        Prefill.build(
          [fuel("A", "1", 1, "10"), junk, fuel("B", "2", 1, "20")],
          c,
          u,
          :payment_details
        )

      assert length(seed.attrs.payment_details) == 2
      assert "1 document in the file could not be read as a receipt." in seed.warnings

      one = Prefill.build([fuel("A", "1", 1, "10"), junk], c, u, :payment_details)
      assert one.attrs.descriptions == "A #1"
      assert "1 document in the file could not be read as a receipt." in one.warnings
    end

    test "nothing recognised → today's not-recognised seed", %{c: c, u: u} do
      junk = %Extracted{
        recognized: false,
        summary: "Photo of a cheque",
        warnings: ["Not recognised as a bill or receipt."]
      }

      seed = Prefill.build([junk], c, u, :payment_details)
      assert seed.attrs == %{descriptions: "Photo of a cheque"}
      assert seed.warnings == ["Not recognised as a bill or receipt."]
    end

    test "receipt with no total: 0 line and a warning naming it", %{c: c, u: u} do
      docs = [fuel("A", "1", 1, "10"), %{fuel("Shell Juru", "S-9", 1, "1") | total: nil}]
      seed = Prefill.build(docs, c, u, :payment_details)

      line = Enum.find(seed.attrs.payment_details, &(&1["descriptions"] =~ "Shell Juru"))
      assert Decimal.eq?(line["unit_price"], 0)
      assert Decimal.eq?(seed.attrs.funds_amount, Decimal.new("10"))
      assert "Shell Juru #S-9: no total read — its line is 0.00." in seed.warnings
    end

    test "per-receipt warnings carry the receipt's name", %{c: c, u: u} do
      bad = %{fuel("Shell Juru", "S-9", 1, "10") | warnings: ["Receipt lines don't add up: x"]}
      seed = Prefill.build([fuel("A", "1", 1, "10"), bad], c, u, :payment_details)
      assert "Shell Juru #S-9: Receipt lines don't add up: x" in seed.warnings
    end

    test "the kind leads the line text; no kind, no prefix", %{c: c, u: u} do
      docs = [
        %{fuel("Shell Juru", "S-9", 2, "60.00") | kind: "Fuel"},
        fuel("PLUS", "T-1", 1, "5")
      ]

      seed = Prefill.build(docs, c, u, :payment_details)

      assert Enum.map(seed.attrs.payment_details, & &1["descriptions"]) ==
               ["Fuel · Shell Juru #S-9 #{dmy(2)}", "PLUS #T-1 #{dmy(1)}"]
    end

    test "a receipt with no date sorts last and is not the pay date", %{c: c, u: u} do
      docs = [%{fuel("Nodate", "N-1", 0, "5") | date: nil}, fuel("A", "1", 4, "10")]
      seed = Prefill.build(docs, c, u, :payment_details)

      assert Enum.map(seed.attrs.payment_details, & &1["descriptions"]) ==
               ["A #1 #{dmy(4)}", "Nodate #N-1"]

      assert seed.attrs.payment_date == Date.add(Date.utc_today(), -4)
      refute Enum.any?(seed.warnings, &(&1 =~ "Receipts are dated"))
    end

    test "no shop names read: plain count, no 'from 0 shops'", %{c: c, u: u} do
      docs = for i <- 1..3, do: %{fuel("x", "#{i}", 1, "10") | supplier_name: nil}
      seed = Prefill.build(docs, c, u, :payment_details)

      assert seed.attrs.descriptions == "3 receipts"
      assert "3 receipts — pick the payee (e.g. the salesperson)." in seed.warnings
      assert hd(seed.attrs.payment_details)["descriptions"] == "#1 #{dmy(1)}"
    end

    test "41 receipts: the first 40 read are used, with a split warning", %{c: c, u: u} do
      docs = for i <- 1..41, do: fuel("Shop#{i}", "#{i}", 1, "1")
      seed = Prefill.build(docs, c, u, :payment_details)

      assert length(seed.attrs.payment_details) == 40
      refute Enum.any?(seed.attrs.payment_details, &(&1["descriptions"] =~ "Shop41 "))

      assert "41 receipts read; only the first 40 were used. Split the claim into two Payments." in seed.warnings
    end

    test "pur invoice with 2 bills: the first is used, with a warning", %{c: c, u: u} do
      seed =
        Prefill.build(
          [ex(), ex(%{doc_no: "B-2", supplier_name: "Other"})],
          c,
          u,
          :pur_invoice_details
        )

      assert seed.attrs.e_inv_internal_id == "A12345"

      assert "The file shows 2 bills — only the first was used. One Purchase Invoice per bill." in seed.warnings
    end
  end
end
