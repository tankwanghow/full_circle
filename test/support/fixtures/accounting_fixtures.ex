defmodule FullCircle.AccountingFixtures do
  def unique_account_name, do: "account#{System.unique_integer()}"

  def valid_account_attributes(attrs \\ %{}) do
    actype =
      FullCircle.Accounting.account_types()
      |> Enum.at((FullCircle.Accounting.account_types() |> Enum.count() |> :rand.uniform()) - 1)

    Enum.into(attrs, %{
      name: unique_account_name(),
      account_type: actype,
      descriptions: "some descriptions"
    })
  end

  def account_fixture(attrs, company, user) do
    attrs = attrs |> valid_account_attributes()

    {:ok, account} =
      FullCircle.StdInterface.create(
        FullCircle.Accounting.Account,
        "account",
        attrs,
        company,
        user
      )

    account
  end

  def fixed_asset_fixture(company, user, attrs \\ %{}) do
    ac = account_fixture(%{account_type: "Fixed Asset"}, company, user)

    FullCircle.Repo.insert!(
      struct(
        FullCircle.Accounting.FixedAsset,
        Map.merge(
          %{
            company_id: company.id,
            name: "Lorry WXX #{System.unique_integer([:positive])}",
            pur_date: ~D[2024-01-01],
            pur_price: Decimal.new("150000"),
            depre_start_date: ~D[2024-01-01],
            residual_value: Decimal.new("0"),
            depre_method: "No Depreciation",
            depre_rate: Decimal.new("0"),
            depre_interval: "Yearly",
            asset_ac_id: ac.id,
            depre_ac_id: ac.id,
            cume_depre_ac_id: ac.id,
            disp_fund_ac_id: ac.id
          },
          attrs
        )
      )
    )
  end
end
