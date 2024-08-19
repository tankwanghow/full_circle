defmodule FullCircle.HR.EmployeePhoto do
  use FullCircle.Schema
  import Ecto.Changeset

  schema "employee_photos" do
    field(:photo_data, :binary)
    field(:photo_descriptor, {:array, :float})
    field(:photo_type, :string)
    field(:flag, :string)
    belongs_to(:employee, FullCircle.HR.Employee)
    belongs_to(:company, FullCircle.Sys.Company)

    timestamps(updated_at: false, type: :utc_datetime)
  end

  @doc false
  def changeset(photo, attrs) do
    photo
    |> cast(attrs, [
      :photo_descriptor,
      :photo_data,
      :photo_type,
      :flag,
      :employee_id,
      :company_id
    ])
    |> validate_required([
      :photo_descriptor,
      :photo_data,
      :photo_type,
      :flag,
      :employee_id,
      :company_id
    ])
  end
end
