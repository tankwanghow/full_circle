defmodule FullCircle.HR.Statutory.EpfFormat do
  @moduledoc "EPF (KWSP) submission rows. Output mirrors the legacy epf_submit_file_format_query."

  @cols ["epf_no", "id_number", "name", "wages", "employer", "employee"]

  # _code is unused for EPF (the legacy query computes but never emits it).
  def rows(contribs, _code) do
    rows =
      contribs
      |> Enum.filter(fn c -> pos?(c.epf_employer) or pos?(c.epf_employee) end)
      |> Enum.map(fn c ->
        [
          c.epf_no,
          c.id_no,
          c.name,
          Decimal.round(to_dec(c.wages), 2),
          Decimal.round(to_dec(c.epf_employer), 0),
          Decimal.round(to_dec(c.epf_employee), 0)
        ]
      end)

    {@cols, rows}
  end

  defp to_dec(%Decimal{} = d), do: d
  defp to_dec(n), do: Decimal.new("#{n}")
  defp pos?(v), do: Decimal.gt?(to_dec(v), 0)
end
