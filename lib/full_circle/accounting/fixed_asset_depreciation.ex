defmodule FullCircle.Accounting.FixedAssetDepreciation do
  use Ecto.Schema
  import Ecto.Changeset
  import FullCircleWeb.Gettext
  import FullCircle.Helpers

  schema "fixed_assets" do
    field(:depre_method, :string)
    field(:depre_rate, :decimal)
    field(:depre_start_date, :date)
    field(:descriptions, :string)
    field(:name, :string)
    field(:pur_date, :date)
    field(:pur_price, :decimal)
    field(:residual_value, :decimal)

    belongs_to(:company, FullCircle.Sys.Company)
    belongs_to(:asset_ac, FullCircle.Accounting.Account, foreign_key: :asset_ac_id)
    belongs_to(:depre_ac, FullCircle.Accounting.Account, foreign_key: :depre_ac_id)

    field(:asset_ac_name, :string, virtual: true)
    field(:depre_ac_name, :string, virtual: true)

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(fixed_asset, attrs) do
    fixed_asset
    |> cast(attrs, [
      :name,
      :pur_date,
      :pur_price,
      :descriptions,
      :depre_start_date,
      :residual_value,
      :depre_method,
      :depre_rate,
      :company_id,
      :asset_ac_id,
      :depre_ac_id,
      :cume_depre_ac_id,
      :asset_ac_name,
      :depre_ac_name
    ])
    |> validate_required([
      :name,
      :pur_date,
      :pur_price,
      :depre_start_date,
      :residual_value,
      :depre_method,
      :depre_rate,
      :asset_ac_name,
      :depre_ac_name
    ])
    |> validate_id(:asset_ac_name, :asset_ac_id)
    |> validate_id(:depre_ac_name, :depre_ac_id)
    |> validate_inclusion(:depre_method, FullCircle.Accounting.depreciation_methods(),
      message: gettext("not in list")
    )
    |> unsafe_validate_unique([:name, :company_id], FullCircle.Repo,
      message: gettext("has already been taken")
    )
    |> unique_constraint(:name,
      name: :fixed_assets_unique_name_in_company,
      message: gettext("has already been taken")
    )
  end
end
