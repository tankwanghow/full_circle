defmodule FullCircle.HR.PayPrep do
  use FullCircle.Schema
  import Ecto.Changeset

  schema "pay_preps" do
    field(:pay_month, :integer)
    field(:pay_year, :integer)
    field(:verified, :boolean, default: false)
    field(:verified_at, :utc_datetime)

    belongs_to(:company, FullCircle.Sys.Company)
    belongs_to(:employee, FullCircle.HR.Employee)
    belongs_to(:funds_account, FullCircle.Accounting.Account)
    belongs_to(:verified_by, FullCircle.UserAccounts.User)

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(pp, attrs) do
    pp
    |> cast(attrs, [
      :pay_month,
      :pay_year,
      :verified,
      :verified_at,
      :company_id,
      :employee_id,
      :funds_account_id,
      :verified_by_id
    ])
    |> validate_required([:pay_month, :pay_year, :company_id, :employee_id])
    |> validate_inclusion(:pay_month, 1..12)
    |> then(fn cs ->
      if get_field(cs, :verified) do
        validate_required(cs, [:funds_account_id])
      else
        cs
      end
    end)
    |> unique_constraint([:company_id, :employee_id, :pay_month, :pay_year],
      name: :pay_preps_unique_period,
      message: "already exists"
    )
  end
end
