defmodule FullCircle.HR.StatutoryCalc do
  use FullCircle.Schema
  import Ecto.Changeset
  use Gettext, backend: FullCircleWeb.Gettext

  schema "statutory_calcs" do
    field(:code, :string)
    field(:name, :string)
    field(:effective_from, :date)
    field(:script, :string)
    belongs_to(:company, FullCircle.Sys.Company)
    timestamps(type: :utc_datetime)
  end

  def changeset(sc, attrs) do
    sc
    |> cast(attrs, [:code, :name, :effective_from, :script, :company_id])
    |> validate_required([:code, :name, :effective_from, :script, :company_id])
    |> validate_format(:code, ~r/^[a-z0-9_]+$/,
      message: gettext("only lowercase letters, digits and underscore")
    )
    |> validate_script()
    |> unique_constraint([:company_id, :code, :effective_from],
      name: :statutory_calcs_unique_code_effective,
      message: gettext("a version with this effective date already exists")
    )
  end

  defp validate_script(cs) do
    case get_field(cs, :script) do
      nil ->
        cs

      script ->
        case FullCircle.PayScript.validate(script, %{}) do
          :ok ->
            cs

          {:error, errors} ->
            Enum.reduce(errors, cs, fn e, acc -> add_error(acc, :script, Exception.message(e)) end)
        end
    end
  end
end
