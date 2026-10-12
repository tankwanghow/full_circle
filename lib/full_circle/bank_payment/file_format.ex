defmodule FullCircle.BankPayment.FileFormat do
  use FullCircle.Schema
  import Ecto.Changeset
  use Gettext, backend: FullCircleWeb.Gettext

  schema "bank_file_formats" do
    field :code, :string
    field :name, :string
    field :effective_from, :date
    field :spec, :map
    belongs_to :company, FullCircle.Sys.Company
    timestamps(type: :utc_datetime)
  end

  def changeset(ff, attrs) do
    ff
    |> cast(attrs, [:code, :name, :effective_from, :spec, :company_id])
    |> validate_required([:code, :name, :effective_from, :spec, :company_id])
    |> validate_format(:code, ~r/^[a-z0-9_]+$/,
      message: gettext("only lowercase letters, digits and underscore")
    )
    |> validate_spec()
    |> unique_constraint([:company_id, :code, :effective_from],
      name: :bank_file_formats_unique_code_effective,
      error_key: :effective_from,
      message: gettext("a version with this effective date already exists")
    )
  end

  defp validate_spec(cs) do
    case get_field(cs, :spec) do
      spec when is_map(spec) and map_size(spec) > 0 ->
        case FullCircle.BankPayment.validate_spec(spec) do
          :ok -> cs
          {:error, errors} -> Enum.reduce(errors, cs, &add_error(&2, :spec, &1))
        end

      _ ->
        cs
    end
  end
end
