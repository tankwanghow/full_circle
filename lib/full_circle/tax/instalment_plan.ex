defmodule FullCircle.Tax.InstalmentPlan do
  use FullCircle.Schema
  import Ecto.Changeset

  schema "tax_instalment_plans" do
    field(:fy_year, :integer)
    field(:tolerance_pct, :decimal, default: Decimal.new("30"))
    field(:estimate, :decimal, default: Decimal.new("0"))
    field(:estimate_month, :integer, default: 1)
    field(:paid_overrides, :map, default: %{})

    belongs_to(:company, FullCircle.Sys.Company)

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(plan, attrs) do
    plan
    |> cast(attrs, [
      :fy_year,
      :tolerance_pct,
      :estimate,
      :estimate_month,
      :paid_overrides,
      :company_id
    ])
    |> validate_required([:company_id, :fy_year])
    |> validate_number(:fy_year, greater_than: 1900, less_than: 2200)
    |> validate_number(:tolerance_pct, greater_than_or_equal_to: 0)
    |> validate_number(:estimate, greater_than_or_equal_to: 0)
    |> validate_inclusion(:estimate_month, 1..12)
    |> unique_constraint([:company_id, :fy_year],
      name: :tax_instalment_plans_unique_period,
      message: "already exists"
    )
  end
end
