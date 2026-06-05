defmodule FullCircle.HR.Statutory.EisFormat do
  @moduledoc "EIS submission. Single 'textstr' fixed-width line per employee, mirroring legacy."
  import FullCircle.HR.Statutory.FixedWidth

  def rows(contribs, code) do
    lines =
      contribs
      |> Enum.filter(fn c ->
        pos?(c.eis_employer) or pos?(c.eis_employee) or pos?(c.eis_employer_only)
      end)
      |> Enum.map(fn c ->
        total = c.eis_employer |> dec() |> add(c.eis_employee) |> add(c.eis_employer_only)

        [
          pad_t(code, 12),
          pad_t("", 20),
          pad_t(String.replace(idnum(c), "-", ""), 12),
          pad_t(String.upcase(c.name), 150),
          two(c.pay_month),
          four(c.pay_year),
          cents(total, 14),
          pad_t("", 9)
        ]
        |> Enum.join()
      end)
      |> Enum.map(&[&1])

    {["textstr"], lines}
  end
end
