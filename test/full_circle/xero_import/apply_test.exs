defmodule FullCircle.XeroImport.ApplyTest do
  use FullCircle.DataCase

  alias FullCircle.{Accounting, Repo}
  alias FullCircle.Accounting.Transaction
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

  test "reset deletes and recreates", %{user: user, snap: snap, name: name} do
    {:ok, %{company: com1}} = Apply.run(snap, user, company_name: name, stop_after: :masters)

    assert {:ok, %{company: com2}} =
             Apply.run(snap, user, company_name: name, reset: true, stop_after: :masters)

    assert com1.id != com2.id
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
