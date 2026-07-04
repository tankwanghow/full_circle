defmodule FullCircle.Tax.InstalmentPlan do
  use FullCircle.Schema
  import Ecto.Changeset

  schema "tax_instalment_plans" do
    field(:fy_year, :integer)
    field(:tolerance_pct, :decimal, default: Decimal.new("30"))
    field(:estimate, :decimal, default: Decimal.new("0"))
    field(:estimate_month, :integer, default: 1)
    field(:paid_overrides, :map, default: %{})
    # CP204A: %{revision_month => revised annual estimate} — only "6"/"9"/"11" are honoured
    field(:revisions, :map, default: %{})
    # Manually entered latest estimate for the preceding YA (85% floor base when
    # no prior-year plan exists in the app; overrides it when > 0).
    field(:prior_year_estimate, :decimal, default: Decimal.new("0"))
    field(:remedy_director_count, :integer, default: 1)
    field(:remedy_existing_income, :decimal, default: Decimal.new(0))

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
      :revisions,
      :prior_year_estimate,
      :remedy_director_count,
      :remedy_existing_income,
      :company_id
    ])
    |> validate_required([:company_id, :fy_year])
    |> validate_number(:fy_year, greater_than: 1900, less_than: 2200)
    |> validate_number(:tolerance_pct, greater_than_or_equal_to: 0)
    |> validate_number(:estimate, greater_than_or_equal_to: 0)
    |> validate_number(:prior_year_estimate, greater_than_or_equal_to: 0)
    |> validate_inclusion(:estimate_month, 1..12)
    |> validate_number(:remedy_director_count, greater_than_or_equal_to: 1, less_than_or_equal_to: 20)
    |> validate_number(:remedy_existing_income, greater_than_or_equal_to: 0)
    |> unique_constraint([:company_id, :fy_year],
      name: :tax_instalment_plans_unique_period,
      message: "already exists"
    )
  end
end
