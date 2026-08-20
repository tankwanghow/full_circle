defmodule FullCircle.XeroImport.ReconcileTest do
  use FullCircle.DataCase

  alias FullCircle.{Accounting, Repo}
  alias FullCircle.Accounting.Transaction
  alias FullCircle.XeroImport
  alias FullCircle.XeroImport.{Apply, Reconcile}

  setup do
    user = FullCircle.UserAccountsFixtures.user_fixture()
    {:ok, snap} = XeroImport.read_snapshot(XeroImport.fixture_dir())
    name = "Xero Recon #{System.unique_integer([:positive])}"

    {:ok, %{company: company}} = Apply.run(snap, user, company_name: name)

    %{user: user, snap: snap, company: company, name: name}
  end

  test "matching apply returns ok with all checks passing", %{
    snap: snap,
    company: company,
    user: user
  } do
    assert {:ok, %{checks: checks}} = Reconcile.run(snap, company, user)
    assert length(checks) == 7
    assert Enum.all?(checks, & &1.ok?)
  end

  test "maps Xero TB names onto FC control accounts", %{
    snap: snap,
    company: company,
    user: user
  } do
    tb =
      Enum.map(snap.reports["trial_balance"], fn
        %{"account_name" => "Account Receivables"} = row ->
          Map.put(row, "account_name", "Accounts Receivable")

        %{"account_name" => "Account Payables"} = row ->
          Map.put(row, "account_name", "Accounts Payable")

        row ->
          row
      end)

    snap = put_in(snap.reports["trial_balance"], tb)

    assert {:ok, %{checks: checks}} = Reconcile.run(snap, company, user)
    tb_check = Enum.find(checks, &(&1.name == :trial_balance))
    assert tb_check.ok?
  end

  test "TB names carrying Xero code suffixes match FC accounts", %{
    snap: snap,
    company: company,
    user: user
  } do
    tb =
      Enum.map(snap.reports["trial_balance"], fn row ->
        Map.update!(row, "account_name", &(&1 <> " (090)"))
      end)

    snap = put_in(snap.reports["trial_balance"], tb)

    assert {:ok, %{checks: checks}} = Reconcile.run(snap, company, user)
    tb_check = Enum.find(checks, &(&1.name == :trial_balance))
    assert tb_check.ok?
  end

  test "P&L accounts reconcile in aggregate with Retained Earnings", %{
    snap: snap,
    company: company,
    user: user
  } do
    # Simulate a multi-year org: Xero TB shows zero YTD Sales, with prior
    # years folded into the computed Retained Earnings line.
    tb =
      Enum.map(snap.reports["trial_balance"], fn
        %{"account_name" => "Sales"} = row -> Map.put(row, "balance", 0.0)
        %{"account_name" => "Retained Earnings"} = row -> Map.put(row, "balance", -81190.0)
        row -> row
      end)

    snap = put_in(snap.reports["trial_balance"], tb)

    assert {:ok, %{checks: checks}} = Reconcile.run(snap, company, user)
    tb_check = Enum.find(checks, &(&1.name == :trial_balance))
    assert tb_check.ok?
  end

  test "fa_nbv groups suffixed duplicate asset names under the Xero name", %{
    user: user,
    snap: snap
  } do
    dup =
      snap.fixed_assets
      |> List.first()
      |> Map.merge(%{"AssetId" => "fa-van-dup", "BookValue" => 80000.0})

    snap =
      %{snap | fixed_assets: snap.fixed_assets ++ [dup]}
      |> put_in([Access.key(:reports), "fa_nbv"], [%{"name" => "Van 1", "nbv" => 160_000.0}])

    name = "Xero Recon FA #{System.unique_integer([:positive])}"
    {:ok, %{company: com}} = Apply.run(snap, user, company_name: name)

    assert {:ok, %{checks: checks}} = Reconcile.run(snap, com, user)
    fa = Enum.find(checks, &(&1.name == :fa_nbv))
    assert fa.ok?
  end

  test "honors control-account overrides when remapping TB names", %{
    snap: snap,
    company: company,
    user: user
  } do
    tb =
      Enum.map(snap.reports["trial_balance"], fn
        %{"account_name" => "Account Receivables"} = row ->
          Map.put(row, "account_name", "Trade Debtors")

        row ->
          row
      end)

    snap = put_in(snap.reports["trial_balance"], tb)
    overrides = %{"control_accounts" => %{"Trade Debtors" => "Account Receivables"}}

    assert {:ok, %{checks: checks}} =
             Reconcile.run(snap, company, user, overrides: overrides)

    tb_check = Enum.find(checks, &(&1.name == :trial_balance))
    assert tb_check.ok?
  end

  test "unallocated credit note reduces live aged receivables", %{user: user, snap: snap} do
    note = %{
      "CreditNoteID" => "cn-unalloc",
      "CreditNoteNumber" => "CN-UNALLOC",
      "Type" => "ACCRECCREDIT",
      "Status" => "AUTHORISED",
      "Contact" => %{"ContactID" => "ct-alice"},
      "Date" => "2024-02-15",
      "LineAmountTypes" => "Exclusive",
      "CurrencyCode" => "MYR",
      "Total" => 30.0,
      "LineItems" => [
        %{
          "Description" => "Goodwill credit",
          "Quantity" => 1.0,
          "UnitAmount" => 30.0,
          "AccountCode" => "200",
          "TaxType" => "NONE",
          "LineAmount" => 30.0
        }
      ]
    }

    snap =
      %{snap | credit_notes: [note]}
      |> put_in([Access.key(:reports), "aged_receivables"], [
        %{"contact_name" => "Alice Customer", "balance" => 90.0}
      ])
      |> update_in([Access.key(:reports), "trial_balance"], fn tb ->
        Enum.map(tb, fn
          %{"account_name" => "Account Receivables"} = row -> Map.put(row, "balance", 90.0)
          %{"account_name" => "Sales"} = row -> Map.put(row, "balance", -60.0)
          row -> row
        end)
      end)

    name = "Xero Recon CN #{System.unique_integer([:positive])}"
    {:ok, %{company: com}} = Apply.run(snap, user, company_name: name)

    assert {:ok, %{checks: checks}} = Reconcile.run(snap, com, user)
    aged = Enum.find(checks, &(&1.name == :aged_receivables))
    assert aged.ok?
  end

  test "off-by-0.01 fails with TB diff printing both sides", %{
    snap: snap,
    company: company,
    user: user
  } do
    acc = Accounting.get_account_by_name("Cheque Account", company, user)

    Repo.insert!(%Transaction{
      company_id: company.id,
      account_id: acc.id,
      doc_type: "Journal",
      doc_no: "DRIFT-1",
      doc_date: ~D[2024-02-20],
      amount: Decimal.new("0.01"),
      particulars: "drift"
    })

    assert {:error, %{checks: checks}} = Reconcile.run(snap, company, user)

    tb = Enum.find(checks, &(&1.name == :trial_balance))
    assert tb
    refute tb.ok?

    diff =
      Enum.find(tb.diffs, fn d ->
        Map.get(d, :account_name) == "Cheque Account" or Map.get(d, :key) == "Cheque Account"
      end)

    assert diff
    assert Map.has_key?(diff, :xero)
    assert Map.has_key?(diff, :full_circle)
    assert Map.has_key?(diff, :delta)
    assert Decimal.eq?(Decimal.abs(diff.delta), Decimal.new("0.01"))
  end

  test "mix --reconcile against applied fixture", %{
    user: user,
    company: company
  } do
    Mix.Task.rerun("full_circle.import_xero", [
      "--reconcile",
      "--snapshot-dir",
      XeroImport.fixture_dir(),
      "--user",
      user.email,
      "--company",
      company.name,
      "--log",
      "false"
    ])
  end

  test "mix --reconcile without user exits 1" do
    System.delete_env("FC_IMPORT_USER")

    assert catch_exit(
             Mix.Task.rerun("full_circle.import_xero", [
               "--reconcile",
               "--snapshot-dir",
               XeroImport.fixture_dir(),
               "--company",
               "Xero Recon Missing User",
               "--log",
               "false"
             ])
           ) == {:shutdown, 1}
  end
end
