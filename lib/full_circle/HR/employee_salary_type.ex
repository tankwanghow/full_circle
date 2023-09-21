defmodule FullCircle.HR.EmployeeSalaryType do
  use FullCircle.Schema
  import Ecto.Changeset
  import FullCircleWeb.Gettext
  import FullCircle.Helpers

  schema "employee_salary_types" do
    field(:_persistent_id, :integer)
    field(:amount, :decimal, default: 0)

    belongs_to(:employee, FullCircle.HR.Employee)
    belongs_to(:salary_type, FullCircle.HR.SalaryType)

    field(:delete, :boolean, virtual: true, default: false)
    field(:salary_type_name, :string, virtual: true)
    field(:employee_name, :string, virtual: true)
  end

  @doc false
  def changeset(est, attrs) do
    est
    |> cast(attrs, [
      :_persistent_id,
      :amount,
      :salary_type_name,
      :employee_name,
      :employee_id,
      :salary_type_id,
      :delete
    ])
    |> validate_required([
      :amount,
      :employee_id,
      :salary_type_id,
      :salary_type_name
    ])
    |> validate_id(:salary_type_name, :salary_type_id)
    |> validate_id(:employee_name, :employee_id)
    |> unique_constraint(:salary_type_id,
      name: :employee_salary_types_unique_name_in_employee,
      message: gettext("has already been taken")
    )
    |> unsafe_validate_unique([:salary_type_id, :employee_id], FullCircle.Repo,
      message: gettext("has already been taken")
    )
    |> maybe_mark_for_deletion()
  end

  defp maybe_mark_for_deletion(%{data: %{id: nil}} = changeset), do: changeset

  defp maybe_mark_for_deletion(changeset) do
    if get_change(changeset, :delete) do
      %{changeset | action: :delete}
    else
      changeset
    end
  end
end
