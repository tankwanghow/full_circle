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
end
