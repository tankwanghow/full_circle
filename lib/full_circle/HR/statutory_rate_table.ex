defmodule FullCircle.HR.StatutoryRateTable do
  use FullCircle.Schema
  import Ecto.Changeset
  use Gettext, backend: FullCircleWeb.Gettext

  schema "statutory_rate_tables" do
    field(:code, :string)
    field(:effective_from, :date)
    field(:columns, {:array, :string})
    field(:rows, {:array, {:array, :float}})
    belongs_to(:company, FullCircle.Sys.Company)
    timestamps(type: :utc_datetime)
  end

  def changeset(rt, attrs) do
    rt
    |> cast(attrs, [:code, :effective_from, :columns, :rows, :company_id])
    |> validate_required([:code, :effective_from, :columns, :rows, :company_id])
    |> validate_format(:code, ~r/^[a-z0-9_]+$/,
      message: gettext("only lowercase letters, digits and underscore")
    )
    |> validate_length(:columns, min: 3)
    |> validate_brackets()
    |> unique_constraint([:company_id, :code, :effective_from],
      name: :statutory_rate_tables_unique_code_effective,
      message: gettext("a version with this effective date already exists")
    )
  end

  defp validate_brackets(cs) do
    columns = get_field(cs, :columns) || []
    rows = get_field(cs, :rows) || []
    width = length(columns)

    cond do
      rows == [] ->
        add_error(cs, :rows, gettext("must have at least one row"))

      Enum.any?(rows, fn r -> length(r) != width end) ->
        add_error(cs, :rows, gettext("every row must have one value per column"))

      Enum.any?(rows, fn [from, to | _] -> from >= to end) ->
        add_error(cs, :rows, gettext("bracket 'from' must be less than 'to'"))

      not contiguous?(rows) and get_field(cs, :code) != "pcb_normal" ->
        add_error(cs, :rows, gettext("brackets must be contiguous and ascending"))

      true ->
        cs
    end
  end

  defp contiguous?(rows) do
    rows
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.all?(fn [[_, to | _], [from, _ | _]] -> to == from end)
  end
end