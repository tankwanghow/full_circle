defmodule FullCircle.HR.TimeAttend do
  use FullCircle.Schema
  import Ecto.Changeset

  schema "time_attendences" do
    field(:flag, :string)
    field(:punch_time, :utc_datetime)

    belongs_to(:company, FullCircle.Sys.Company)
    belongs_to(:employee, FullCircle.HR.Employee)
  end

  @doc false
  def changeset(st, attrs) do
    st
    |> cast(attrs, [
      :flag,
      :punch_time,
      :company_id,
      :employee_id
    ])
    |> validate_required([
      :flag,
      :punch_time,
      :company_id,
      :employee_id
    ])
  end
end
