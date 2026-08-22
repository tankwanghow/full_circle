defmodule FullCircle.XeroImport.Gapless do
  import Ecto.Query, warn: false

  alias FullCircle.Repo
  alias FullCircle.Sys.GaplessDocId

  @prefixes %{
    Invoice: "INV",
    PurInvoice: "PINV",
    Receipt: "RC",
    Payment: "PV",
    CreditNote: "CN",
    DebitNote: "DN",
    Journal: "JS"
  }

  def prefix(type), do: Map.fetch!(@prefixes, type)

  @doc """
  Set `gapless_doc_ids.current` to the max integer seen for each prefix.

  Only numbers matching `^PREFIX-(\\d+)$` move the counter (`INV-000123` → 123).
  `SI-88` and `BILL-10` are stored as-is and ignored.
  """
  def bump(company, imported_numbers_by_type) when is_map(imported_numbers_by_type) do
    Enum.each(@prefixes, fn {type, prefix} ->
      numbers = numbers_for(imported_numbers_by_type, type)

      case max_matching(prefix, numbers) do
        nil -> :ok
        n -> bump_type(company, type_name(type), n)
      end
    end)

    :ok
  end

  defp numbers_for(map, type) do
    Map.get(map, type) || Map.get(map, type_name(type)) || []
  end

  defp type_name(type) when is_atom(type), do: Atom.to_string(type)
  defp type_name(type) when is_binary(type), do: type

  defp max_matching(prefix, numbers) do
    numbers
    |> Enum.flat_map(&parse_digits(prefix, &1))
    |> Enum.max(fn -> nil end)
  end

  defp parse_digits(prefix, number) when is_binary(number) do
    case Regex.run(~r/^#{Regex.escape(prefix)}-(\d+)$/, number) do
      [_, digits] -> [String.to_integer(digits)]
      _ -> []
    end
  end

  defp parse_digits(_prefix, _), do: []

  defp bump_type(company, doc_type, n) do
    gap =
      Repo.one(
        from g in GaplessDocId,
          where: g.company_id == ^company.id and g.doc_type == ^doc_type
      )

    cond do
      is_nil(gap) ->
        :ok

      n > gap.current ->
        gap
        |> Ecto.Changeset.change(%{current: n})
        |> Repo.update!()

      true ->
        :ok
    end
  end
end
