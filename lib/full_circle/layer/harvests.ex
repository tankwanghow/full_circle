defmodule FullCircle.Layer.Harvest do
  use FullCircle.Schema
  import Ecto.Changeset
  import FullCircle.Helpers
  import FullCircleWeb.Gettext

  schema "harvests" do
    belongs_to :company, FullCircle.Sys.Company
    field :harvest_no, :string
    field :har_date, :date
    belongs_to :employee, FullCircle.HR.Employee

    field :employee_name, :string, virtual: true

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(note, attrs) do
    note
    |> cast(attrs, [
      :harvest_no,
      :employee_id,
      :employee_name,
      :har_date,
      :company_id
    ])
    |> validate_required([
      :harvest_no,
      :employee_name,
      :har_date
    ])
    |> validate_id(:employee_name, :employee_id)
    |> validate_date(:har_date, days_before: 2)
    |> validate_date(:har_date, days_after: 2)
    |> unsafe_validate_unique([:harvest_no, :company_id], FullCircle.Repo,
      message: gettext("already in company")
    )
  end
end
