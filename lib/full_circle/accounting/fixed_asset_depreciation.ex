defmodule FullCircle.Accounting.FixedAssetDepreciation do
  use FullCircle.Schema
  import Ecto.Changeset
  import FullCircleWeb.Gettext

  schema "fixed_asset_depreciations" do
    field(:cost_basis, :decimal)
    field(:depre_date, :date)
    field(:amount, :decimal)

    belongs_to(:fixed_asset, FullCircle.Accounting.FixedAsset, foreign_key: :fixed_asset_id)
    belongs_to(:transaction, FullCircle.Accounting.Transaction, foreign_key: :transaction_id)

    field(:closed, :boolean, virtual: true)
    field(:cume_depre, :decimal, virtual: true)

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(depreciation, attrs) do
    depreciation
    |> cast(attrs, [
      :cost_basis,
      :depre_date,
      :amount,
      :fixed_asset_id,
      :closed,
      :transaction_id
    ])
    |> validate_required([
      :cost_basis,
      :depre_date,
      :amount,
      :fixed_asset_id
    ])
    |> unsafe_validate_unique([:depre_date, :fixed_asset_id], FullCircle.Repo,
      message: gettext("duplicated depreciation date")
    )
    |> validate_number(:amount, greater_than: 0)
    |> validate_number(:cost_basis, greater_than: 0)
  end
end
