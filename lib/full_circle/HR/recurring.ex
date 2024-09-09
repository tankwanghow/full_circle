defmodule FullCircle.HR.Recurring do
  use FullCircle.Schema
  import Ecto.Changeset
  use Gettext, backend: FullCircleWeb.Gettext
  import FullCircle.Helpers

  schema "recurrings" do
    field(:recur_no, :string)
    field(:recur_date, :date)
    field(:amount, :decimal)
    field(:target_amount, :decimal)
    field(:start_date, :date)
    field(:descriptions, :string)
    field(:status, :string)

    belongs_to(:company, FullCircle.Sys.Company)
    belongs_to(:employee, FullCircle.HR.Employee)
    belongs_to(:salary_type, FullCircle.HR.SalaryType)

    has_many(:salary_notes, FullCircle.HR.SalaryNote, on_delete: :delete_all)

    field(:employee_name, :string, virtual: true)
    field(:salary_type_name, :string, virtual: true)

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(recur, attrs) do
    recur
    |> cast(attrs, [
      :recur_no,
      :recur_date,
      :amount,
      :target_amount,
      :employee_name,
      :employee_id,
      :start_date,
      :salary_type_id,
      :salary_type_name,
      :status,
      :descriptions,
      :company_id
    ])
    |> validate_required([
      :recur_no,
      :recur_date,
      :amount,
      :target_amount,
      :start_date,
      :employee_name,
      :salary_type_name,
      :company_id
    ])
    |> validate_id(:employee_name, :employee_id)
    |> validate_id(:salary_type_name, :salary_type_id)
    |> fill_today(:recur_date)
    |> validate_date(:recur_date, days_before: 5)
    |> validate_length(:descriptions, max: 230)
    |> validate_date(:recur_date, days_after: 5)
    |> validate_date(:start_date, days_before: 0)
    |> unsafe_validate_unique([:recur_no, :company_id], FullCircle.Repo,
      message: gettext("has already been taken")
    )
    |> unique_constraint(:recur_no,
      name: :recurrings_unique_recur_no_in_company,
      message: gettext("has already been taken")
    )
  end
end
