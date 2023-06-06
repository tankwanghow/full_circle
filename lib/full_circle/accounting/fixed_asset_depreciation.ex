defmodule FullCircle.Accounting.FixedAssetDepreciation do
  use FullCircle.Schema
  import Ecto.Changeset

  schema "fixed_asset_depreciations" do
    field(:cost_basis, :decimal)
    field(:depre_date, :date)
    field(:amount, :decimal)

    belongs_to(:fixed_asset, FullCircle.Accounting.FixedAsset, foreign_key: :fixed_asset_id)
    belongs_to(:transaction, FullCircle.Accounting.Transaction, foreign_key: :transaction_id)

    field(:closed, :boolean, virtual: true)

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
  end
end
