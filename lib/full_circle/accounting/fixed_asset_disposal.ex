defmodule FullCircle.Accounting.FixedAssetDisposal do
  use FullCircle.Schema
  import Ecto.Changeset

  schema "fixed_asset_disposals" do
    field(:disp_date, :date)
    field(:amount, :decimal)

    belongs_to(:fixed_asset, FullCircle.Accounting.FixedAsset, foreign_key: :fixed_asset_id)
    belongs_to(:transaction, FullCircle.Accounting.Transaction, foreign_key: :transaction_id)

    field(:closed, :boolean, virtual: true)

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(disposal, attrs) do
    disposal
    |> cast(attrs, [
      :disp_date,
      :amount,
      :fixed_asset_id,
      :closed,
      :transaction_id
    ])
    |> validate_required([
      :disp_date,
      :amount,
      :fixed_asset_id
    ])
    |> FullCircle.Accounting.validate_depre_date(:disp_date)
    |> FullCircle.Accounting.validate_earlier_than_depreciation_start_date(:disp_date)
    |> validate_number(:amount, greater_than: 0)
  end
end
