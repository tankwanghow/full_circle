defmodule FullCircle.HR.Statutory.SocsoEisFormat do
  @moduledoc """
  Combined SOCSO+EIS submission line.

  Follows PERKESO "Combine SOCSO + EIS Contribution Text File Format" V2.0
  (dated 13 Feb 2026), which inserts the SKBBK / Lindung 24 Jam employee
  contribution as field 11 at positions 239-244, carved from the old trailing
  filler (40 -> 6 + 34). Total line length remains 278. V2.0 is mandatory from
  1 October 2026.
  """
  import FullCircle.HR.Statutory.FixedWidth

  def rows(contribs, code) do
    lines =
      contribs
      |> Enum.filter(fn c ->
        pos?(c.socso_employer) or pos?(c.socso_employee) or pos?(c.socso_employer_only) or
          pos?(c.eis_employer) or pos?(c.eis_employee) or pos?(c.eis_employer_only) or
          pos?(c.socso_24hour)
      end)
      |> Enum.map(fn c ->
        socso_er = c.socso_employer |> dec() |> add(c.socso_employer_only)
        eis_er = c.eis_employer |> dec() |> add(c.eis_employer_only)

        [
          pad_t(code, 12),
          pad_t("", 20),
          pad_t(String.replace(idnum(c), "-", ""), 12),
          pad_t(String.upcase(c.name), 150),
          two(c.pay_month),
          four(c.pay_year),
          cents(c.wages, 14),
          cents(socso_er, 6),
          cents(c.socso_employee, 6),
          cents(eis_er, 6),
          cents(c.eis_employee, 6),
          cents(c.socso_24hour, 6),
          pad_t("", 34)
        ]
        |> Enum.join()
      end)
      |> Enum.map(&[&1])

    {["textstr"], lines}
  end
end
