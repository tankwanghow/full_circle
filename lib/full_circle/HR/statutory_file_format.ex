defmodule FullCircle.HR.StatutoryFileFormat do
  use FullCircle.Schema
  import Ecto.Changeset
  use Gettext, backend: FullCircleWeb.Gettext

  schema "statutory_file_formats" do
    field(:code, :string)
    field(:name, :string)
    field(:effective_from, :date)
    field(:renderer, :string, default: "text")
    field(:spec, :map)
    belongs_to(:company, FullCircle.Sys.Company)
    timestamps(type: :utc_datetime)
  end

  def changeset(ff, attrs) do
    ff
    |> cast(attrs, [:code, :name, :effective_from, :renderer, :spec, :company_id])
    |> validate_required([:code, :name, :effective_from, :renderer, :spec, :company_id])
    |> validate_format(:code, ~r/^[a-z0-9_]+$/,
      message: gettext("only lowercase letters, digits and underscore")
    )
    |> validate_inclusion(:renderer, ["text"])
    |> validate_spec_shape()
    |> unique_constraint([:company_id, :code, :effective_from],
      name: :statutory_file_formats_unique_code_effective,
      message: gettext("a version with this effective date already exists")
    )
  end

  defp validate_spec_shape(changeset) do
    company_id = get_field(changeset, :company_id)
    spec = get_field(changeset, :spec)

    if company_id && is_map(spec) && map_size(spec) > 0 do
      case FullCircle.FileSpec.validate(spec, FullCircle.StatutoryConfig.file_format_variables(company_id)) do
        :ok -> changeset
        {:error, errors} -> Enum.reduce(errors, changeset, &add_error(&2, :spec, &1))
      end
    else
      changeset
    end
  end
end