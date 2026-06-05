defmodule FullCircle.HR.Statutory.SocsoEisFormat do
  @moduledoc "Combined SOCSO+EIS submission line, mirroring legacy socso_eis_submit_file_format_query."
  import FullCircle.HR.Statutory.FixedWidth

  def rows(contribs, code) do
    lines =
      contribs
      |> Enum.filter(fn c ->
        pos?(c.socso_employer) or pos?(c.socso_employee) or pos?(c.socso_employer_only) or
          pos?(c.eis_employer) or pos?(c.eis_employee) or pos?(c.eis_employer_only)
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
          pad_t("", 40)
        ]
        |> Enum.join()
      end)
      |> Enum.map(&[&1])

    {["textstr"], lines}
  end
end
