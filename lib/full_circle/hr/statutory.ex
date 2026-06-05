defmodule FullCircle.HR.Statutory do
  @moduledoc "Entry point for statutory submission files (EPF/SOCSO/EIS/SOCSO+EIS/PCB)."

  alias FullCircle.HR
  alias FullCircle.HR.Statutory.{EpfFormat, SocsoFormat, EisFormat, SocsoEisFormat, PcbFormat}

  @doc "Settings key holding the employer code for a report."
  def code_key("EPF"), do: "epf_code"
  def code_key("SOCSO"), do: "socso_code"
  def code_key("EIS"), do: "eis_code"
  def code_key("SOCSO+EIS"), do: "socso_code"
  def code_key("PCB"), do: "pcb_code"

  @doc "{col, rows} for the CSV-style reports (EPF/SOCSO/EIS/SOCSO+EIS)."
  def rows(report, month, year, code, com_id) do
    contribs = HR.statutory_contributions(month, year, com_id)

    case report do
      "EPF" -> EpfFormat.rows(contribs, code)
      "SOCSO" -> SocsoFormat.rows(contribs, code)
      "EIS" -> EisFormat.rows(contribs, code)
      "SOCSO+EIS" -> SocsoEisFormat.rows(contribs, code)
    end
  end

  @doc "Raw CP39 text for PCB."
  def pcb_text(month, year, code, com_id) do
    contribs = HR.statutory_contributions(month, year, com_id)
    PcbFormat.text(contribs, code, month, year)
  end
end
