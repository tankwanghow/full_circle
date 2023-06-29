defmodule FullCircle.Accounting.FixedAssetDepreciation do
  use FullCircle.Schema
  import FullCircle.Helpers
  import Ecto.Changeset

  schema "fixed_asset_depreciations" do
    field(:cost_basis, :decimal)
    field(:depre_date, :date)
    field(:amount, :decimal)
    field(:is_seed, :boolean, default: false)
    field(:doc_no, :string)

    belongs_to(:fixed_asset, FullCircle.Accounting.FixedAsset, foreign_key: :fixed_asset_id)

    field(:cume_depre, :decimal, virtual: true)
    field(:fixed_asset_name, :string, virtual: true)

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(depreciation, attrs) do
    depreciation
    |> cast(attrs, [
      :cost_basis,
      :depre_date,
      :amount,
      :fixed_asset_name,
      :fixed_asset_id,
      :doc_no,
      :is_seed
    ])
    |> validate_required([
      :cost_basis,
      :depre_date,
      :amount,
      :fixed_asset_id,
      :is_seed
    ])
    |> validate_id(:fixed_asset_name, :fixed_asset_id)
    |> FullCircle.Accounting.validate_depre_date(:depre_date)
    |> FullCircle.Accounting.validate_earlier_than_depreciation_start_date(:depre_date)
    |> validate_number(:amount, greater_than: 0)
    |> validate_number(:cost_basis, greater_than: 0)
  end
end
