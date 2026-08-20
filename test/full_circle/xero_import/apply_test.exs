defmodule FullCircle.XeroImport.ApplyTest do
  use FullCircle.DataCase

  alias FullCircle.{Accounting, Repo, XeroImport}
  alias FullCircle.Accounting.{Contact, TaxCode, Transaction}
  alias FullCircle.Billing.{Invoice, InvoiceDetail}
  alias FullCircle.XeroImport.Apply

  setup do
    user = FullCircle.UserAccountsFixtures.user_fixture()
    {:ok, snap} = FullCircle.XeroImport.read_snapshot(FullCircle.XeroImport.fixture_dir())
    name = "Xero Fixture #{System.unique_integer([:positive])}"
    %{user: user, snap: snap, name: name}
  end

  test "creates accounts without duplicating AR/AP", %{user: user, snap: snap, name: name} do
    assert {:ok, %{company: com, id_map: map}} =
             Apply.run(snap, user, company_name: name, stop_after: :masters)

    names =
      Repo.all(
        from a in FullCircle.Accounting.Account, where: a.company_id == ^com.id, select: a.name
      )

    assert "Account Receivables" in names
    refute "Accounts Receivable" in names
    assert "Sales" in names
    assert "Cheque Account" in names

    assert map["account:ac-ar"] ==
             Accounting.get_account_by_name("Account Receivables", com, user).id
  end

  test "aborts without reset if company already has invoices", %{
    user: user,
    snap: snap,
    name: name
  } do
    {:ok, %{company: com}} = Apply.run(snap, user, company_name: name, stop_after: :masters)

    acc = Accounting.get_account_by_name("Sales", com, user)

    Repo.insert!(%Transaction{
      company_id: com.id,
      account_id: acc.id,
      doc_type: "Journal",
      doc_no: "DIRTY-1",
      doc_date: ~D[2024-01-01],
      amount: Decimal.new("1.00"),
      particulars: "dirty"
    })

    assert {:error, :company_not_empty} =
             Apply.run(snap, user, company_name: name, stop_after: :masters)
  end

  test "aborts without reset if company already has contacts or goods", %{
    user: user,
    snap: snap,
    name: name
  } do
    {:ok, com} =
      FullCircle.Sys.create_company(
        %{
          name: name,
          country: "Malaysia",
          timezone: "Asia/Kuala_Lumpur",
          closing_month: 12,
          closing_day: 31
        },
        user
      )

    Repo.insert!(%Contact{company_id: com.id, name: "Pre-existing Customer"})

    assert {:error, :company_not_empty} = Apply.run(snap, user, company_name: name)
  end

  test "reset deletes and recreates", %{user: user, snap: snap, name: name} do
    {:ok, %{company: com1}} = Apply.run(snap, user, company_name: name, stop_after: :masters)

    assert {:ok, %{company: com2}} =
             Apply.run(snap, user, company_name: name, reset: true, stop_after: :masters)

    assert com1.id != com2.id
  end

  test "reset deletes and recreates a fully imported company", %{
    user: user,
    snap: snap,
    name: name
  } do
    # Include a bank SPEND so the company holds payment_details rows —
    # their RESTRICT FKs onto accounts/goods must not block deletion.
    snap = %{
      snap
      | bank_transactions: [
          %{
            "BankTransactionID" => "bt-reset-1",
            "Type" => "SPEND",
            "Status" => "AUTHORISED",
            "BankAccount" => %{"AccountID" => "ac-bank"},
            "Contact" => %{"ContactID" => "ct-bob"},
            "Date" => "2024-02-20",
            "CurrencyCode" => "MYR",
            "Total" => 15.0,
            "LineItems" => [
              %{
                "Description" => "Supplies",
                "Quantity" => 1.0,
                "UnitAmount" => 15.0,
                "AccountCode" => "200",
                "TaxType" => "NONE",
                "LineAmount" => 15.0
              }
            ]
          }
        ]
    }

    {:ok, %{company: com1}} = Apply.run(snap, user, company_name: name)

    assert {:ok, %{company: com2}} =
             Apply.run(snap, user, company_name: name, reset: true)

    assert com1.id != com2.id

    refute Repo.exists?(from c in FullCircle.Sys.Company, where: c.id == ^com1.id)
    refute Repo.exists?(from t in Transaction, where: t.company_id == ^com1.id)
  end

  test "straight-line asset is seeded and depre rows do not post GL", %{
    user: user,
    snap: snap,
    name: name
  } do
    {:ok, %{company: com}} = Apply.run(snap, user, company_name: name, stop_after: :masters)
    fa = Repo.one!(from f in FullCircle.Accounting.FixedAsset, where: f.company_id == ^com.id)
    assert fa.name == "Van 1"
    assert Decimal.eq?(fa.depre_rate, Decimal.new("0.2"))

    depre =
      Repo.all(
        from d in FullCircle.Accounting.FixedAssetDepreciation, where: d.fixed_asset_id == ^fa.id
      )

    assert depre != []
    assert Enum.all?(depre, & &1.is_seed)

    refute Repo.exists?(
             from t in Transaction,
               where: t.company_id == ^com.id and t.doc_type == "fixed_asset_depreciations"
           )
  end

  test "missing disposal account is seeded instead of failing the asset", %{
    user: user,
    snap: snap,
    name: name
  } do
    snap =
      %{snap | accounts: Enum.reject(snap.accounts, &(&1["Name"] == "Gain on Disposal"))}
      |> update_in([Access.key(:fixed_assets), Access.at(0), "AssetType"], fn type ->
        Map.delete(type, "DisposalAccountId")
      end)

    assert {:ok, %{company: com}} =
             Apply.run(snap, user, company_name: name, stop_after: :masters)

    assert Repo.exists?(
             from a in FullCircle.Accounting.Account,
               where: a.company_id == ^com.id and a.name == "Gain on Disposal"
           )

    assert Repo.exists?(
             from f in FullCircle.Accounting.FixedAsset, where: f.company_id == ^com.id
           )
  end

  test "post-conversion depreciation history posts GL journals", %{
    user: user,
    snap: snap,
    name: name
  } do
    snap =
      snap
      |> update_in([Access.key(:conversion_balances), "Lines"], fn lines ->
        Enum.reject(lines, &(&1["AccountID"] == "ac-accum"))
      end)
      |> put_in(
        [Access.key(:fixed_assets), Access.at(0), "DepreciationHistory"],
        [
          %{
            "DepreciationDate" => "2024-06-30",
            "DepreciationAmount" => 20000.0,
            "CostLimit" => 100_000.0
          }
        ]
      )

    {:ok, %{company: com, id_map: map}} = Apply.run(snap, user, company_name: name)
    accum_id = map["account:ac-accum"]

    total =
      Repo.one(
        from t in Transaction,
          where: t.company_id == ^com.id and t.account_id == ^accum_id,
          select: coalesce(sum(t.amount), 0)
      )

    assert Decimal.eq?(total, Decimal.new("-20000"))
  end

  test "pre-conversion depreciation history does not post GL (covered by conversion balances)",
       %{user: user, snap: snap, name: name} do
    {:ok, %{company: com, id_map: map}} = Apply.run(snap, user, company_name: name)
    accum_id = map["account:ac-accum"]

    # Fixture history row is dated 2023-12-31, before the 2024-01-01
    # conversion; the -20000 must come only from the conversion balance line.
    total =
      Repo.one(
        from t in Transaction,
          where: t.company_id == ^com.id and t.account_id == ^accum_id,
          select: coalesce(sum(t.amount), 0)
      )

    assert Decimal.eq?(total, Decimal.new("-20000"))
  end

  test "asset with unmapped depreciation account errors instead of crashing", %{
    user: user,
    snap: snap,
    name: name
  } do
    snap =
      update_in(snap, [Access.key(:fixed_assets), Access.at(0), "AssetType"], fn type ->
        Map.delete(type, "AccumulatedDepreciationAccountId")
      end)

    assert {:error, {:unmapped_asset_account, "Van 1", _}} =
             Apply.run(snap, user, company_name: name, stop_after: :masters)
  end

  test "diminishing-value asset aborts", %{user: user, snap: snap, name: name} do
    snap =
      put_in(
        snap,
        [Access.key(:fixed_assets), Access.at(0), "DepreciationMethod"],
        "DiminishingValue"
      )

    assert {:error, {:diminishing_value, _}} =
             Apply.run(snap, user, company_name: name, stop_after: :masters)
  end

  test "imports INV-000123 and does not mint INV-000001", %{user: user, snap: snap, name: name} do
    assert {:ok, %{company: com}} = Apply.run(snap, user, company_name: name)

    inv =
      Repo.one!(
        from i in FullCircle.Billing.Invoice,
          where: i.company_id == ^com.id and i.invoice_no == "INV-000123"
      )

    assert inv.invoice_no == "INV-000123"

    refute Repo.exists?(
             from i in FullCircle.Billing.Invoice,
               where: i.company_id == ^com.id and i.invoice_no == "INV-DRAFT"
           )
  end

  test "receipt matchers settle INV-000123", %{user: user, snap: snap, name: name} do
    {:ok, %{company: com}} = Apply.run(snap, user, company_name: name)

    ar =
      Repo.one!(
        from t in Transaction,
          join: a in FullCircle.Accounting.Account,
          on: a.id == t.account_id,
          where:
            t.company_id == ^com.id and t.doc_no == "INV-000123" and
              a.name == "Account Receivables"
      )

    matched =
      Repo.aggregate(
        from(m in FullCircle.Accounting.TransactionMatcher, where: m.transaction_id == ^ar.id),
        :sum,
        :match_amount
      )

    assert Decimal.eq?(Decimal.add(ar.amount, matched || 0), 0)
  end

  test "bill without an InvoiceNumber falls back to the Xero InvoiceID", %{
    user: user,
    snap: snap,
    name: name
  } do
    bill = %{
      "InvoiceID" => "bill-nonum",
      "Type" => "ACCPAY",
      "Status" => "AUTHORISED",
      "Contact" => %{"ContactID" => "ct-bob"},
      "Date" => "2024-02-05",
      "DueDate" => "2024-03-05",
      "LineAmountTypes" => "Exclusive",
      "CurrencyCode" => "MYR",
      "Total" => 25.0,
      "LineItems" => [
        %{
          "Description" => "Unnumbered bill",
          "Quantity" => 1.0,
          "UnitAmount" => 25.0,
          "AccountCode" => "200",
          "TaxType" => "NONE",
          "LineAmount" => 25.0
        }
      ]
    }

    snap = %{snap | invoices: snap.invoices ++ [bill]}
    {:ok, %{company: com}} = Apply.run(snap, user, company_name: name)

    assert Repo.exists?(
             from p in FullCircle.Billing.PurInvoice,
               where: p.company_id == ^com.id and p.pur_invoice_no == "bill-nonum"
           )
  end

  test "payments sharing a Reference get unique receipt numbers from PaymentID", %{
    user: user,
    snap: snap,
    name: name
  } do
    inv = fn id, no ->
      %{
        "InvoiceID" => id,
        "Type" => "ACCREC",
        "InvoiceNumber" => no,
        "Status" => "AUTHORISED",
        "Contact" => %{"ContactID" => "ct-alice"},
        "Date" => "2024-02-01",
        "DueDate" => "2024-03-01",
        "LineAmountTypes" => "Exclusive",
        "CurrencyCode" => "MYR",
        "Total" => 10.0,
        "LineItems" => [
          %{
            "Description" => "Eggs",
            "Quantity" => 1.0,
            "UnitAmount" => 10.0,
            "AccountCode" => "200",
            "TaxType" => "NONE",
            "LineAmount" => 10.0
          }
        ]
      }
    end

    pay = fn pid, inv_id ->
      %{
        "PaymentID" => pid,
        "Status" => "AUTHORISED",
        "Reference" => "Cash",
        "Amount" => 10.0,
        "Date" => "2024-02-06",
        "Account" => %{"AccountID" => "ac-bank"},
        "Invoice" => %{"InvoiceID" => inv_id, "Type" => "ACCREC"}
      }
    end

    snap = %{
      snap
      | invoices: snap.invoices ++ [inv.("inv-c1", "INV-C1"), inv.("inv-c2", "INV-C2")],
        payments: snap.payments ++ [pay.("pay-c1", "inv-c1"), pay.("pay-c2", "inv-c2")]
    }

    {:ok, %{company: com}} = Apply.run(snap, user, company_name: name)

    nos =
      Repo.all(
        from r in FullCircle.ReceiveFund.Receipt,
          where: r.company_id == ^com.id and r.receipt_no in ["pay-c1", "pay-c2"],
          select: r.receipt_no
      )

    assert Enum.sort(nos) == ["pay-c1", "pay-c2"]
  end

  test "zero-total invoice with cross-account lines imports as a journal", %{
    user: user,
    snap: snap,
    name: name
  } do
    float_inv = %{
      "InvoiceID" => "inv-float",
      "Type" => "ACCREC",
      "InvoiceNumber" => "INV-FLOAT",
      "Status" => "AUTHORISED",
      "Contact" => %{"ContactID" => "ct-alice"},
      "Date" => "2024-02-04",
      "DueDate" => "2024-02-04",
      "LineAmountTypes" => "Exclusive",
      "CurrencyCode" => "MYR",
      "Total" => 0.0,
      "LineItems" => [
        %{
          "Description" => "Opening float",
          "Quantity" => 1.0,
          "UnitAmount" => 250.0,
          "AccountCode" => "090",
          "TaxType" => "NONE",
          "LineAmount" => 250.0
        },
        %{
          "Description" => "Closing float",
          "Quantity" => 1.0,
          "UnitAmount" => -250.0,
          "AccountCode" => "200",
          "TaxType" => "NONE",
          "LineAmount" => -250.0
        }
      ]
    }

    snap = %{snap | invoices: snap.invoices ++ [float_inv]}
    {:ok, %{company: com}} = Apply.run(snap, user, company_name: name)

    refute Repo.exists?(
             from i in Invoice, where: i.company_id == ^com.id and i.invoice_no == "INV-FLOAT"
           )

    txn =
      Repo.one!(
        from t in Transaction,
          join: a in FullCircle.Accounting.Account,
          on: a.id == t.account_id,
          where:
            t.company_id == ^com.id and t.doc_no == "INV-FLOAT" and
              a.name == "Cheque Account"
      )

    assert Decimal.eq?(txn.amount, Decimal.new("250"))
  end

  test "document rounding gap is closed so AR posts exactly the Xero Total", %{
    user: user,
    snap: snap,
    name: name
  } do
    inv = %{
      "InvoiceID" => "inv-round",
      "Type" => "ACCREC",
      "InvoiceNumber" => "INV-ROUND",
      "Status" => "AUTHORISED",
      "Contact" => %{"ContactID" => "ct-alice"},
      "Date" => "2024-02-08",
      "DueDate" => "2024-03-08",
      "LineAmountTypes" => "Exclusive",
      "CurrencyCode" => "MYR",
      "Total" => 10.0,
      "LineItems" => [
        %{
          "Description" => "Rounded line",
          "Quantity" => 1.0,
          "UnitAmount" => 9.99,
          "AccountCode" => "200",
          "TaxType" => "NONE",
          "LineAmount" => 9.99
        }
      ]
    }

    snap = %{snap | invoices: snap.invoices ++ [inv]}
    {:ok, %{company: com}} = Apply.run(snap, user, company_name: name)

    ar =
      Repo.one!(
        from t in Transaction,
          join: a in FullCircle.Accounting.Account,
          on: a.id == t.account_id,
          where:
            t.company_id == ^com.id and t.doc_no == "INV-ROUND" and
              a.name == "Account Receivables"
      )

    assert Decimal.eq?(ar.amount, Decimal.new("10.00"))
  end

  test "aged gaps are attributed to contacts by a final journal", %{
    user: user,
    snap: snap,
    name: name
  } do
    # Xero payroll posts per-contact payables via unreadable system journals:
    # expected aged shows Bob at -50 while documents only explain -30.
    snap =
      put_in(snap, [Access.key(:reports), "aged_payables"], [
        %{"contact_name" => "Bob Supplier", "balance" => -50.0}
      ])

    {:ok, %{company: com}} = Apply.run(snap, user, company_name: name)

    bob_ap =
      Repo.one(
        from t in Transaction,
          join: a in FullCircle.Accounting.Account,
          on: a.id == t.account_id,
          join: c in Contact,
          on: c.id == t.contact_id,
          where:
            t.company_id == ^com.id and a.name == "Account Payables" and
              c.name == "Bob Supplier",
          select: sum(t.amount)
      )

    assert Decimal.eq?(bob_ap, Decimal.new("-50.00"))

    # The attribution journal must not move the account total.
    attribution =
      Repo.one(
        from t in Transaction,
          where: t.company_id == ^com.id and t.doc_no == "XCATCHUP-AGED",
          select: coalesce(sum(t.amount), 0)
      )

    assert Decimal.eq?(attribution, Decimal.new("0"))
  end

  test "zero-total invoices are skipped", %{user: user, snap: snap, name: name} do
    zero = %{
      "InvoiceID" => "inv-zero",
      "Type" => "ACCREC",
      "InvoiceNumber" => "INV-ZERO",
      "Status" => "AUTHORISED",
      "Contact" => %{"ContactID" => "ct-alice"},
      "Date" => "2024-02-04",
      "DueDate" => "2024-02-04",
      "LineAmountTypes" => "Exclusive",
      "CurrencyCode" => "MYR",
      "Total" => 0.0,
      "LineItems" => [
        %{
          "Description" => "No sale",
          "Quantity" => 1.0,
          "UnitAmount" => 0.0,
          "AccountCode" => "200",
          "TaxType" => "NONE",
          "LineAmount" => 0.0
        }
      ]
    }

    snap = %{snap | invoices: snap.invoices ++ [zero]}
    assert {:ok, %{company: com}} = Apply.run(snap, user, company_name: name)

    refute Repo.exists?(
             from i in Invoice, where: i.company_id == ^com.id and i.invoice_no == "INV-ZERO"
           )
  end

  test "duplicate bill numbers get a suffix and keep their own payments", %{
    user: user,
    snap: snap,
    name: name
  } do
    bill = fn id, amt ->
      %{
        "InvoiceID" => id,
        "Type" => "ACCPAY",
        "InvoiceNumber" => "TNB-1",
        "Status" => "AUTHORISED",
        "Contact" => %{"ContactID" => "ct-bob"},
        "Date" => "2024-02-05",
        "DueDate" => "2024-03-05",
        "LineAmountTypes" => "Exclusive",
        "CurrencyCode" => "MYR",
        "Total" => amt,
        "LineItems" => [
          %{
            "Description" => "Electricity",
            "Quantity" => 1.0,
            "UnitAmount" => amt,
            "AccountCode" => "200",
            "TaxType" => "NONE",
            "LineAmount" => amt
          }
        ]
      }
    end

    pay = %{
      "PaymentID" => "pay-dup2",
      "Status" => "AUTHORISED",
      "Amount" => 7.0,
      "Date" => "2024-02-10",
      "Account" => %{"AccountID" => "ac-bank"},
      "Invoice" => %{"InvoiceID" => "bill-dup2", "Type" => "ACCPAY"}
    }

    snap = %{
      snap
      | invoices: snap.invoices ++ [bill.("bill-dup1", 5.0), bill.("bill-dup2", 7.0)],
        payments: snap.payments ++ [pay]
    }

    {:ok, %{company: com}} = Apply.run(snap, user, company_name: name)

    nos =
      Repo.all(
        from p in FullCircle.Billing.PurInvoice,
          where: p.company_id == ^com.id and like(p.pur_invoice_no, "TNB-1%"),
          select: p.pur_invoice_no
      )

    assert Enum.sort(nos) == ["TNB-1", "TNB-1 (2)"]

    ap =
      Repo.one!(
        from t in Transaction,
          join: a in FullCircle.Accounting.Account,
          on: a.id == t.account_id,
          where:
            t.company_id == ^com.id and t.doc_no == "TNB-1 (2)" and
              a.name == "Account Payables"
      )

    matched =
      Repo.aggregate(
        from(m in FullCircle.Accounting.TransactionMatcher, where: m.transaction_id == ^ap.id),
        :sum,
        :match_amount
      )

    assert Decimal.eq?(matched, Decimal.new("7.00"))
  end

  test "AP overpayment refund imports as a receipt against Account Payables", %{
    user: user,
    snap: snap,
    name: name
  } do
    refund = %{
      "PaymentID" => "pay-opref",
      "PaymentType" => "APOVERPAYMENTPAYMENT",
      "Status" => "AUTHORISED",
      "Amount" => 0.01,
      "Date" => "2024-02-25",
      "Account" => %{"AccountID" => "ac-bank"},
      "Invoice" => %{
        "InvoiceID" => "op-1",
        "Type" => "APOVERPAYMENT",
        "Contact" => %{"ContactID" => "ct-bob"}
      }
    }

    snap = %{snap | payments: snap.payments ++ [refund]}
    {:ok, %{company: com}} = Apply.run(snap, user, company_name: name)

    rec =
      Repo.one!(
        from r in FullCircle.ReceiveFund.Receipt,
          where: r.company_id == ^com.id and r.receipt_no == "pay-opref"
      )

    assert Decimal.eq?(rec.funds_amount, Decimal.new("0.01"))

    ap =
      Repo.one!(
        from t in Transaction,
          join: a in FullCircle.Accounting.Account,
          on: a.id == t.account_id,
          where:
            t.company_id == ^com.id and t.doc_no == "pay-opref" and
              a.name == "Account Payables"
      )

    assert Decimal.eq?(ap.amount, Decimal.new("-0.01"))
  end

  test "payment whose invoice is missing aborts", %{user: user, snap: snap, name: name} do
    snap =
      put_in(snap.payments, [
        %{
          "PaymentID" => "pay-bad",
          "Invoice" => %{"InvoiceID" => "nope"},
          "Amount" => 1.0,
          "Date" => "2024-02-01",
          "Account" => %{"AccountID" => "ac-bank"},
          "Status" => "AUTHORISED"
        }
      ])

    assert {:error, {:missing_allocation_target, "pay-bad", "nope"}} =
             Apply.run(snap, user, company_name: name)
  end

  test "failed import rolls back completely and can be rerun", %{
    user: user,
    snap: snap,
    name: name
  } do
    bad_snap =
      put_in(snap.payments, [
        %{
          "PaymentID" => "pay-bad",
          "Invoice" => %{"InvoiceID" => "nope"},
          "Amount" => 1.0,
          "Date" => "2024-02-01",
          "Account" => %{"AccountID" => "ac-bank"},
          "Status" => "AUTHORISED"
        }
      ])

    assert {:error, _} = Apply.run(bad_snap, user, company_name: name)

    refute Repo.exists?(
             from i in Invoice,
               join: c in FullCircle.Sys.Company,
               on: c.id == i.company_id,
               where: c.name == ^name
           )

    assert {:ok, %{company: com}} = Apply.run(snap, user, company_name: name)

    assert Repo.exists?(
             from i in Invoice, where: i.company_id == ^com.id and i.invoice_no == "INV-000123"
           )
  end

  test "gapless sits at 123 after INV-000123; SI-88 does not move it", %{
    user: user,
    snap: snap,
    name: name
  } do
    {:ok, %{company: com}} = Apply.run(snap, user, company_name: name)

    current =
      Repo.one!(
        from g in FullCircle.Sys.GaplessDocId,
          where: g.company_id == ^com.id and g.doc_type == "Invoice",
          select: g.current
      )

    assert current == 123
  end

  test "conversion AR is reduced by imported conversion invoice", %{
    user: user,
    snap: snap,
    name: name
  } do
    {:ok, %{company: com, id_map: map}} = Apply.run(snap, user, company_name: name)
    ar_id = map["account:ac-ar"]
    bank_id = map["account:ac-bank"]

    assert Repo.exists?(
             from i in FullCircle.Billing.Invoice,
               where: i.company_id == ^com.id and i.invoice_no == "CONV-AR-1"
           )

    assert Repo.exists?(
             from t in Transaction,
               where: t.company_id == ^com.id and t.account_id == ^bank_id and t.old_data == true
           )

    refute Repo.exists?(
             from g in FullCircle.Product.Good,
               where: g.company_id == ^com.id and g.name == "Conversion AR"
           )

    assert Repo.exists?(
             from g in FullCircle.Product.Good,
               where: g.company_id == ^com.id and g.name == "__xero_line__"
           )

    seed =
      Repo.all(
        from t in Transaction,
          where: t.company_id == ^com.id and t.account_id == ^ar_id and t.old_data == true
      )

    assert Enum.reduce(seed, Decimal.new(0), &Decimal.add(&2, &1.amount)) |> Decimal.eq?(0)
  end

  test "FC trial balance report sums to zero after year-end closings", %{
    user: user,
    snap: snap,
    name: name
  } do
    # Fixture documents are dated 2024; FC's TB report shows P&L only for
    # the current FY and expects prior years closed into Retained Earnings.
    {:ok, %{company: com}} = Apply.run(snap, user, company_name: name)

    total =
      Date.utc_today()
      |> FullCircle.Reporting.trail_balance(com)
      |> Enum.reduce(Decimal.new(0), &Decimal.add(&2, &1.balance))

    assert Decimal.eq?(total, 0)

    # KPST convention: closing hits ONLY "Net Profit for The Year" + RE, so
    # the P&L report for a closed year keeps every account's history visible.
    pl_2024 = FullCircle.Reporting.profit_loss(~D[2024-12-31], com)
    sales = Enum.find(pl_2024, &(&1.name == "Sales"))
    assert sales, "Sales must stay visible in a closed year's P&L"
    refute Decimal.eq?(sales.balance, 0)

    assert Enum.any?(pl_2024, &(&1.name == "Net Profit for The Year"))

    refute Repo.exists?(
             from t in Transaction,
               join: a in FullCircle.Accounting.Account,
               on: a.id == t.account_id,
               where:
                 t.company_id == ^com.id and like(t.doc_no, "XCLOSE%") and
                   a.name not in ["Net Profit for The Year", "Retained Earnings"]
           )

    re =
      Repo.one(
        from t in Transaction,
          join: a in FullCircle.Accounting.Account,
          on: a.id == t.account_id,
          where:
            t.company_id == ^com.id and a.name == "Retained Earnings" and
              like(t.doc_no, "XCLOSE%"),
          select: coalesce(sum(t.amount), 0)
      )

    refute Decimal.eq?(re, 0)

    # No closing journal for the current, incomplete financial year.
    current_close = "XCLOSE-#{Date.utc_today().year}-12-31"

    refute Repo.exists?(
             from t in Transaction,
               where: t.company_id == ^com.id and t.doc_no == ^current_close
           )
  end

  test "retained earnings override renames the account everywhere", %{
    user: user,
    snap: snap,
    name: name
  } do
    overrides = %{"control_accounts" => %{"Retained Earnings" => "Retained Profits"}}

    {:ok, %{company: com}} =
      Apply.run(snap, user, company_name: name, overrides: overrides)

    assert Accounting.get_account_by_name("Retained Profits", com, user)
    refute Accounting.get_account_by_name("Retained Earnings", com, user)

    # Closings must post to the overridden name, not seed a second account.
    close =
      Repo.one(
        from t in Transaction,
          join: a in FullCircle.Accounting.Account,
          on: a.id == t.account_id,
          where:
            t.company_id == ^com.id and like(t.doc_no, "XCLOSE%") and
              a.name == "Retained Profits",
          select: coalesce(sum(t.amount), 0)
      )

    refute Decimal.eq?(close, 0)

    assert {:ok, _} = FullCircle.XeroImport.Reconcile.run(snap, com, user, overrides: overrides)
  end

  test "yearly TBs generate balanced catch-up journals for unpulled postings", %{
    user: user,
    snap: snap,
    name: name
  } do
    # Simulate Xero system journals we cannot pull (e.g. payroll): the FYE
    # TB shows 50 more Depreciation expense and 50 more AP than the documents
    # explain. A catch-up journal must close exactly that gap.
    lines =
      snap.reports["trial_balance"] ++
        [
          %{"account_name" => "Depreciation (477)", "balance" => 50.0},
          %{"account_name" => "Accounts Payable", "balance" => -50.0}
        ]

    snap =
      put_in(snap, [Access.key(:reports), "trial_balance_by_year"], [
        %{"date" => "2024-12-31", "lines" => lines}
      ])

    {:ok, %{company: com}} = Apply.run(snap, user, company_name: name)

    depre =
      Repo.one!(
        from t in Transaction,
          join: a in FullCircle.Accounting.Account,
          on: a.id == t.account_id,
          where:
            t.company_id == ^com.id and t.doc_no == "XCATCHUP-2024-12-31" and
              a.name == "Depreciation"
      )

    assert Decimal.eq?(depre.amount, Decimal.new("50"))
    assert depre.doc_date == ~D[2024-12-31]

    ap =
      Repo.one!(
        from t in Transaction,
          join: a in FullCircle.Accounting.Account,
          on: a.id == t.account_id,
          where:
            t.company_id == ^com.id and t.doc_no == "XCATCHUP-2024-12-31" and
              a.name == "Account Payables"
      )

    assert Decimal.eq?(ap.amount, Decimal.new("-50"))
  end

  test "matching yearly TBs post no catch-up journals", %{user: user, snap: snap, name: name} do
    # Use FC's internal split (conversion revenue in Sales, not in RE) so
    # every per-account delta is zero.
    lines =
      Enum.map(snap.reports["trial_balance"], fn
        %{"account_name" => "Sales"} = row -> Map.put(row, "balance", -190.0)
        row -> row
      end)

    snap =
      put_in(snap, [Access.key(:reports), "trial_balance_by_year"], [
        %{"date" => "2024-12-31", "lines" => lines}
      ])

    {:ok, %{company: com}} = Apply.run(snap, user, company_name: name)

    refute Repo.exists?(
             from t in Transaction,
               where: t.company_id == ^com.id and like(t.doc_no, "XCATCHUP%")
           )
  end

  test "conversion AP is reduced by imported conversion bill", %{
    user: user,
    snap: snap,
    name: name
  } do
    snap =
      snap
      |> Map.update!(:conversion_balances, fn cb ->
        Map.update!(cb, "Lines", &(&1 ++ [%{"AccountID" => "ac-ap", "Balance" => -30.0}]))
      end)
      |> Map.update!(:invoices, fn invs ->
        invs ++
          [
            %{
              "InvoiceID" => "bill-conv",
              "Type" => "ACCPAY",
              "InvoiceNumber" => "CONV-AP-1",
              "Status" => "AUTHORISED",
              "Contact" => %{"ContactID" => "ct-bob"},
              "Date" => "2024-01-01",
              "DueDate" => "2024-01-31",
              "LineAmountTypes" => "Exclusive",
              "CurrencyCode" => "MYR",
              "Total" => 30.0,
              "LineItems" => [
                %{
                  "Description" => "Conversion AP",
                  "Quantity" => 1.0,
                  "UnitAmount" => 30.0,
                  "AccountCode" => "200",
                  "TaxType" => "NONE",
                  "LineAmount" => 30.0
                }
              ]
            }
          ]
      end)

    {:ok, %{company: com, id_map: map}} = Apply.run(snap, user, company_name: name)
    ap_id = map["account:ac-ap"]

    assert Repo.exists?(
             from i in FullCircle.Billing.PurInvoice,
               where: i.company_id == ^com.id and i.pur_invoice_no == "CONV-AP-1"
           )

    seed =
      Repo.all(
        from t in Transaction,
          where: t.company_id == ^com.id and t.account_id == ^ap_id and t.old_data == true
      )

    assert Enum.reduce(seed, Decimal.new(0), &Decimal.add(&2, &1.amount)) |> Decimal.eq?(0)
  end

  test "parses Xero .NET /Date(ms)/ format", %{} do
    # 1607299200000 ms = 2020-12-07T00:00:00Z; payments and manual journals
    # carry only this format (no ISO DateString).
    assert Apply.conversion_invoice?(
             %{"InvoiceNumber" => "X", "Date" => "/Date(1607299200000+0000)/"},
             "2020-12-07"
           )

    refute Apply.conversion_invoice?(
             %{"InvoiceNumber" => "X", "Date" => "/Date(1607299200000+0000)/"},
             "2020-12-06"
           )

    assert Apply.conversion_invoice?(
             %{"InvoiceNumber" => "X", "Date" => "/Date(1607299200000)/"},
             "2020-12-07"
           )
  end

  test "invoices dated before the conversion date strip conversion AR too", %{
    user: user,
    snap: snap,
    name: name
  } do
    # Xero's normal conversion flow enters open invoices with their original
    # (pre-conversion) dates; they are part of the conversion AR balance.
    assert Apply.conversion_invoice?(
             %{"InvoiceNumber" => "SI-1", "Date" => "2023-12-15"},
             "2024-01-01"
           )

    refute Apply.conversion_invoice?(
             %{"InvoiceNumber" => "SI-1", "Date" => "2024-01-02"},
             "2024-01-01"
           )

    pre = %{
      "InvoiceID" => "inv-pre",
      "Type" => "ACCREC",
      "InvoiceNumber" => "SI-PRE-1",
      "Status" => "AUTHORISED",
      "Contact" => %{"ContactID" => "ct-alice"},
      "Date" => "2023-12-15",
      "DueDate" => "2024-01-15",
      "LineAmountTypes" => "Exclusive",
      "CurrencyCode" => "MYR",
      "Total" => 40.0,
      "LineItems" => [
        %{
          "Description" => "Pre-conversion sale",
          "Quantity" => 1.0,
          "UnitAmount" => 40.0,
          "AccountCode" => "200",
          "TaxType" => "NONE",
          "LineAmount" => 40.0
        }
      ]
    }

    snap =
      snap
      |> Map.update!(:invoices, &(&1 ++ [pre]))
      |> Map.update!(:conversion_balances, fn cb ->
        Map.update!(cb, "Lines", fn lines ->
          Enum.map(lines, fn
            %{"AccountID" => "ac-ar"} = line -> Map.put(line, "Balance", 140.0)
            line -> line
          end)
        end)
      end)

    {:ok, %{company: com, id_map: map}} = Apply.run(snap, user, company_name: name)
    ar_id = map["account:ac-ar"]

    seed =
      Repo.all(
        from t in Transaction,
          where: t.company_id == ^com.id and t.account_id == ^ar_id and t.old_data == true
      )

    assert Enum.reduce(seed, Decimal.new(0), &Decimal.add(&2, &1.amount)) |> Decimal.eq?(0)
  end

  test "payment match_amount uses Xero amount not the full invoice", %{
    user: user,
    snap: snap,
    name: name
  } do
    pay = snap.payments |> List.first() |> Map.put("Amount", 20.0)
    snap = %{snap | payments: [pay]}
    {:ok, %{company: com}} = Apply.run(snap, user, company_name: name)

    ar =
      Repo.one!(
        from t in Transaction,
          join: a in FullCircle.Accounting.Account,
          on: a.id == t.account_id,
          where:
            t.company_id == ^com.id and t.doc_no == "INV-000123" and
              a.name == "Account Receivables"
      )

    matched =
      Repo.aggregate(
        from(m in FullCircle.Accounting.TransactionMatcher, where: m.transaction_id == ^ar.id),
        :sum,
        :match_amount
      )

    assert Decimal.eq?(matched, Decimal.new("-20.00"))
    assert Decimal.eq?(Decimal.add(ar.amount, matched), Decimal.new("30.00"))
  end

  test "contact name collision suffixes (2)", %{user: user, snap: snap, name: name} do
    extra = %{
      "ContactID" => "ct-alice-2",
      "Name" => "Alice Customer",
      "IsCustomer" => true,
      "Addresses" => []
    }

    snap = %{snap | contacts: snap.contacts ++ [extra]}

    {:ok, %{company: com, id_map: map}} =
      Apply.run(snap, user, company_name: name, stop_after: :masters)

    names =
      Repo.all(from c in Contact, where: c.company_id == ^com.id, select: c.name)

    assert "Alice Customer" in names
    assert "Alice Customer (2)" in names
    assert map["contact:ct-alice"] != map["contact:ct-alice-2"]
  end

  test "fixed asset name collision suffixes (2)", %{user: user, snap: snap, name: name} do
    extra =
      snap.fixed_assets
      |> List.first()
      |> Map.merge(%{"AssetId" => "fa-van-2", "AssetName" => "Van 1"})

    snap = %{snap | fixed_assets: snap.fixed_assets ++ [extra]}

    {:ok, %{company: com, id_map: map}} =
      Apply.run(snap, user, company_name: name, stop_after: :masters)

    names =
      Repo.all(
        from f in FullCircle.Accounting.FixedAsset,
          where: f.company_id == ^com.id,
          select: f.name
      )

    assert "Van 1" in names
    assert "Van 1 (2)" in names
    assert map["asset:fa-van"] != map["asset:fa-van-2"]
  end

  test "sales-only item defaults its purchase side instead of crashing", %{
    user: user,
    snap: snap,
    name: name
  } do
    item = %{
      "ItemID" => "it-tray",
      "Code" => "TRAY",
      "Name" => "Egg Tray",
      "SalesDetails" => %{"UnitPrice" => 2.0, "AccountCode" => "200", "TaxType" => "OUTPUT"},
      "PurchaseDetails" => %{}
    }

    snap = %{snap | items: snap.items ++ [item]}

    assert {:ok, %{company: com}} =
             Apply.run(snap, user, company_name: name, stop_after: :masters)

    good =
      Repo.one!(
        from g in FullCircle.Product.Good,
          where: g.company_id == ^com.id and g.name == "Egg Tray"
      )

    assert good.purchase_account_id != nil
  end

  test "zero-rate Xero taxes reuse NoSTax/NoPTax", %{user: user, snap: snap, name: name} do
    {:ok, %{company: com}} = Apply.run(snap, user, company_name: name, stop_after: :masters)

    codes =
      Repo.all(from t in TaxCode, where: t.company_id == ^com.id, select: t.code)

    assert "NoSTax" in codes
    assert "NoPTax" in codes
    refute Enum.any?(codes, &String.contains?(&1, "TaxExempt"))
  end

  test "does not persist AROVERPAYMENT as an invoice", %{user: user, snap: snap, name: name} do
    over = %{
      "InvoiceID" => "inv-over",
      "Type" => "AROVERPAYMENT",
      "InvoiceNumber" => "OVER-1",
      "Status" => "AUTHORISED",
      "Contact" => %{"ContactID" => "ct-alice", "Name" => "Alice Customer"},
      "Date" => "2024-02-01",
      "DueDate" => "2024-03-01",
      "LineAmountTypes" => "Exclusive",
      "CurrencyCode" => "MYR",
      "Total" => 10.0,
      "LineItems" => [
        %{
          "Description" => "Overpayment",
          "Quantity" => 1.0,
          "UnitAmount" => 10.0,
          "AccountCode" => "200",
          "TaxType" => "NONE",
          "LineAmount" => 10.0
        }
      ]
    }

    snap = %{snap | invoices: snap.invoices ++ [over]}
    {:ok, %{company: com}} = Apply.run(snap, user, company_name: name)

    refute Repo.exists?(
             from i in Invoice, where: i.company_id == ^com.id and i.invoice_no == "OVER-1"
           )
  end

  test "RECEIVE-OVERPAYMENT is imported as a receipt", %{user: user, snap: snap, name: name} do
    snap = %{
      snap
      | bank_transactions: [
          %{
            "BankTransactionID" => "bt-over-1",
            "Type" => "RECEIVE-OVERPAYMENT",
            "Status" => "AUTHORISED",
            "BankAccount" => %{"AccountID" => "ac-bank"},
            "Contact" => %{"ContactID" => "ct-alice"},
            "Date" => "2024-02-20",
            "CurrencyCode" => "MYR",
            "Total" => 12.0,
            "LineItems" => [
              %{
                "Description" => "Customer overpay",
                "Quantity" => 1.0,
                "UnitAmount" => 12.0,
                "AccountCode" => "200",
                "TaxType" => "NONE",
                "LineAmount" => 12.0
              }
            ]
          }
        ]
    }

    {:ok, %{company: com}} = Apply.run(snap, user, company_name: name)

    rec =
      Repo.one!(
        from r in FullCircle.ReceiveFund.Receipt,
          where: r.company_id == ^com.id and r.receipt_no == "bt-over-1"
      )

    assert Decimal.eq?(rec.funds_amount, Decimal.new("12.00"))
  end

  test "inclusive line amounts are netted before FC tax", %{user: user, snap: snap, name: name} do
    inv = %{
      "InvoiceID" => "inv-incl",
      "Type" => "ACCREC",
      "InvoiceNumber" => "INV-INCL",
      "Status" => "AUTHORISED",
      "Contact" => %{"ContactID" => "ct-alice", "Name" => "Alice Customer"},
      "Date" => "2024-02-01",
      "DueDate" => "2024-03-01",
      "LineAmountTypes" => "Inclusive",
      "CurrencyCode" => "MYR",
      "Total" => 53.0,
      "LineItems" => [
        %{
          "Description" => "Egg",
          "Quantity" => 10.0,
          "UnitAmount" => 5.3,
          "AccountCode" => "200",
          "ItemCode" => "EGG",
          "TaxType" => "OUTPUT",
          "LineAmount" => 53.0
        }
      ]
    }

    snap = %{snap | invoices: snap.invoices ++ [inv]}
    {:ok, %{company: com}} = Apply.run(snap, user, company_name: name)

    detail =
      Repo.one!(
        from d in InvoiceDetail,
          join: i in Invoice,
          on: d.invoice_id == i.id,
          where: i.company_id == ^com.id and i.invoice_no == "INV-INCL"
      )

    assert Decimal.eq?(Decimal.round(detail.unit_price, 2), Decimal.new("5.00"))
  end

  test "discounted line keeps Xero LineAmount via negative discount", %{
    user: user,
    snap: snap,
    name: name
  } do
    inv = %{
      "InvoiceID" => "inv-disc",
      "Type" => "ACCREC",
      "InvoiceNumber" => "INV-DISC",
      "Status" => "AUTHORISED",
      "Contact" => %{"ContactID" => "ct-alice", "Name" => "Alice Customer"},
      "Date" => "2024-02-01",
      "DueDate" => "2024-03-01",
      "LineAmountTypes" => "Exclusive",
      "CurrencyCode" => "MYR",
      "Total" => 180.0,
      "LineItems" => [
        %{
          "Description" => "Discounted egg trays",
          "Quantity" => 2.0,
          "UnitAmount" => 100.0,
          "DiscountRate" => 10.0,
          "AccountCode" => "200",
          "TaxType" => "NONE",
          "LineAmount" => 180.0
        }
      ]
    }

    snap = %{snap | invoices: snap.invoices ++ [inv]}
    {:ok, %{company: com}} = Apply.run(snap, user, company_name: name)

    detail =
      Repo.one!(
        from d in InvoiceDetail,
          join: i in Invoice,
          on: d.invoice_id == i.id,
          where: i.company_id == ^com.id and i.invoice_no == "INV-DISC"
      )

    assert Decimal.eq?(detail.discount, Decimal.new("-20"))

    net = Decimal.add(Decimal.mult(detail.quantity, detail.unit_price), detail.discount)
    assert Decimal.eq?(net, Decimal.new("180"))
  end

  test "negative-quantity correction line keeps its Xero LineAmount", %{
    user: user,
    snap: snap,
    name: name
  } do
    inv = %{
      "InvoiceID" => "inv-negqty",
      "Type" => "ACCREC",
      "InvoiceNumber" => "INV-NEGQTY",
      "Status" => "AUTHORISED",
      "Contact" => %{"ContactID" => "ct-alice", "Name" => "Alice Customer"},
      "Date" => "2024-02-01",
      "DueDate" => "2024-03-01",
      "LineAmountTypes" => "Exclusive",
      "CurrencyCode" => "MYR",
      "Total" => 150.0,
      "LineItems" => [
        %{
          "Description" => "Eggs",
          "Quantity" => 4.0,
          "UnitAmount" => 50.0,
          "AccountCode" => "200",
          "TaxType" => "NONE",
          "LineAmount" => 200.0
        },
        %{
          "Description" => "Returned tray",
          "Quantity" => -1.0,
          "UnitAmount" => 50.0,
          "AccountCode" => "200",
          "TaxType" => "NONE",
          "LineAmount" => -50.0
        }
      ]
    }

    snap = %{snap | invoices: snap.invoices ++ [inv]}
    {:ok, %{company: com}} = Apply.run(snap, user, company_name: name)

    details =
      Repo.all(
        from d in InvoiceDetail,
          join: i in Invoice,
          on: d.invoice_id == i.id,
          where: i.company_id == ^com.id and i.invoice_no == "INV-NEGQTY"
      )

    total =
      Enum.reduce(details, Decimal.new(0), fn d, acc ->
        d.quantity |> Decimal.mult(d.unit_price) |> Decimal.add(d.discount) |> Decimal.add(acc)
      end)

    assert Decimal.eq?(total, Decimal.new("150"))
  end

  test "discounted credit note line folds the discount into unit_price", %{
    user: user,
    snap: snap,
    name: name
  } do
    note = %{
      "CreditNoteID" => "cn-disc",
      "CreditNoteNumber" => "CN-DISC",
      "Type" => "ACCRECCREDIT",
      "Status" => "AUTHORISED",
      "Contact" => %{"ContactID" => "ct-alice"},
      "Date" => "2024-02-10",
      "LineAmountTypes" => "Exclusive",
      "CurrencyCode" => "MYR",
      "Total" => 180.0,
      "LineItems" => [
        %{
          "Description" => "Discounted return",
          "Quantity" => 2.0,
          "UnitAmount" => 100.0,
          "DiscountRate" => 10.0,
          "AccountCode" => "200",
          "TaxType" => "NONE",
          "LineAmount" => 180.0
        }
      ]
    }

    snap = %{snap | credit_notes: [note]}
    {:ok, %{company: com}} = Apply.run(snap, user, company_name: name)

    detail =
      Repo.one!(
        from d in FullCircle.DebCre.CreditNoteDetail,
          join: n in FullCircle.DebCre.CreditNote,
          on: d.credit_note_id == n.id,
          where: n.company_id == ^com.id and n.note_no == "CN-DISC"
      )

    assert Decimal.eq?(Decimal.mult(detail.quantity, detail.unit_price), Decimal.new("180"))
  end

  test "mix --apply writes id_map.json next to the snapshot", %{user: user, name: name} do
    src = XeroImport.fixture_dir()
    dir = Path.join(System.tmp_dir!(), "xero-idmap-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    for file <- File.ls!(src), String.ends_with?(file, ".json") do
      File.cp!(Path.join(src, file), Path.join(dir, file))
    end

    on_exit(fn -> File.rm_rf(dir) end)

    Mix.Task.rerun("full_circle.import_xero", [
      "--apply",
      "--snapshot-dir",
      dir,
      "--user",
      user.email,
      "--company",
      name,
      "--log",
      "false"
    ])

    path = Path.join(dir, "id_map.json")
    assert File.exists?(path)
    {:ok, map} = Jason.decode(File.read!(path))
    assert is_binary(map["account:ac-ar"])
    assert is_binary(map["contact:ct-alice"])
  end

  test "mix --apply --reset refuses to delete an existing company without confirmation", %{
    user: user,
    snap: snap,
    name: name
  } do
    {:ok, %{company: com}} = Apply.run(snap, user, company_name: name)

    src = XeroImport.fixture_dir()
    dir = Path.join(System.tmp_dir!(), "xero-reset-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    for file <- File.ls!(src), String.ends_with?(file, ".json") do
      File.cp!(Path.join(src, file), Path.join(dir, file))
    end

    old_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)

    on_exit(fn ->
      Mix.shell(old_shell)
      File.rm_rf(dir)
    end)

    send(self(), {:mix_shell_input, :yes?, false})

    catch_exit(
      Mix.Task.rerun("full_circle.import_xero", [
        "--apply",
        "--reset",
        "--snapshot-dir",
        dir,
        "--user",
        user.email,
        "--company",
        name,
        "--log",
        "false"
      ])
    )

    assert Repo.exists?(from c in FullCircle.Sys.Company, where: c.id == ^com.id)
  end

  test "bank transfer with blank Reference gets default particulars", %{
    user: user,
    snap: snap,
    name: name
  } do
    snap = %{
      snap
      | bank_transfers: [
          %{
            "BankTransferID" => "xfer-blank",
            "Status" => "AUTHORISED",
            "Reference" => "",
            "Date" => "2024-02-22",
            "Amount" => 40.0,
            "FromBankAccount" => %{"AccountID" => "ac-bank"},
            "ToBankAccount" => %{"AccountID" => "ac-bank2"}
          }
        ],
        accounts:
          snap.accounts ++
            [%{"AccountID" => "ac-bank2", "Code" => "091", "Name" => "Petty Bank", "Type" => "BANK"}]
    }

    {:ok, %{company: com}} = Apply.run(snap, user, company_name: name)

    txn =
      Repo.one!(
        from t in Transaction,
          join: a in FullCircle.Accounting.Account,
          on: a.id == t.account_id,
          where:
            t.company_id == ^com.id and t.doc_no == "xfer-blank" and a.name == "Petty Bank"
      )

    assert txn.particulars == "Bank transfer"
  end

  test "negative-total SPEND imports as a receipt with positive amounts", %{
    user: user,
    snap: snap,
    name: name
  } do
    snap = %{
      snap
      | bank_transactions: [
          %{
            "BankTransactionID" => "bt-neg-1",
            "Type" => "SPEND",
            "Status" => "AUTHORISED",
            "BankAccount" => %{"AccountID" => "ac-bank"},
            "Contact" => %{"ContactID" => "ct-bob"},
            "Date" => "2024-02-21",
            "CurrencyCode" => "MYR",
            "Total" => -1.3,
            "LineItems" => [
              %{
                "Description" => "Wrongly entered amount",
                "Quantity" => 1.0,
                "UnitAmount" => -1.3,
                "AccountCode" => "200",
                "TaxType" => "NONE",
                "LineAmount" => -1.3
              }
            ]
          }
        ]
    }

    {:ok, %{company: com}} = Apply.run(snap, user, company_name: name)

    rec =
      Repo.one!(
        from r in FullCircle.ReceiveFund.Receipt,
          where: r.company_id == ^com.id and r.receipt_no == "bt-neg-1"
      )

    assert Decimal.eq?(rec.funds_amount, Decimal.new("1.30"))

    refute Repo.exists?(
             from p in FullCircle.BillPay.Payment,
               where: p.company_id == ^com.id and p.payment_no == "bt-neg-1"
           )
  end

  test "imports a SPEND bank transaction as a payment", %{user: user, snap: snap, name: name} do
    snap = %{
      snap
      | bank_transactions: [
          %{
            "BankTransactionID" => "bt-spend-1",
            "Type" => "SPEND",
            "Status" => "AUTHORISED",
            "BankAccount" => %{"AccountID" => "ac-bank"},
            "Contact" => %{"ContactID" => "ct-bob"},
            "Date" => "2024-02-20",
            "CurrencyCode" => "MYR",
            "Total" => 15.0,
            "LineItems" => [
              %{
                "Description" => "Office supplies",
                "Quantity" => 1.0,
                "UnitAmount" => 15.0,
                "AccountCode" => "200",
                "TaxType" => "NONE",
                "LineAmount" => 15.0
              }
            ]
          }
        ]
    }

    {:ok, %{company: com}} = Apply.run(snap, user, company_name: name)

    pay =
      Repo.one!(
        from p in FullCircle.BillPay.Payment,
          where: p.company_id == ^com.id and p.payment_no == "bt-spend-1"
      )

    assert Decimal.eq?(pay.funds_amount, Decimal.new("15.00"))

    refute Repo.exists?(
             from m in FullCircle.Accounting.TransactionMatcher,
               where: m.doc_type == "Payment" and m.doc_id == ^pay.id
           )
  end
end
