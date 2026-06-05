defmodule FullCircle.HR.Statutory.PcbFormat do
  @moduledoc """
  LHDN e-Data PCB (CP39) monthly file. ASCII, CRLF line endings, amounts in cents.
  Header 57 chars; detail 136 chars. CP38 is always zero (system computes PCB only).
  """
  import FullCircle.HR.Statutory.FixedWidth, only: [dec: 1, pos?: 1]

  @doc "Full file text. `tin` = 10-digit employer TIN (digits of the E-number)."
  def text(contribs, tin, month, year) do
    details = Enum.filter(contribs, fn c -> pos?(c.pcb_employee) end)

    total_cents =
      details
      |> Enum.reduce(Decimal.new(0), fn c, acc -> Decimal.add(acc, dec(c.pcb_employee)) end)
      |> to_cents()

    header =
      "H" <>
        pad0(tin, 10) <>
        pad0(tin, 10) <>
        pad0(year, 4) <>
        pad0(month, 2) <>
        zfill(total_cents, 10) <>
        zfill(length(details), 5) <>
        zfill(0, 10) <>
        zfill(0, 5)

    detail_lines = Enum.map(details, &detail/1)

    ([header] ++ detail_lines)
    |> Enum.join("\r\n")
    |> Kernel.<>("\r\n")
  end

  @doc "Filename matching the existing tool: `pcb List_<YYYYMMDDhhmmss>.txt`."
  def filename(now \\ NaiveDateTime.utc_now()) do
    stamp = Calendar.strftime(now, "%Y%m%d%H%M%S")
    "pcb List_#{stamp}.txt"
  end

  defp detail(c) do
    "D" <>
      pad0(digits(c.tax_no), 11) <>
      String.pad_trailing(c.name, 60) <>
      String.pad_trailing("", 12) <>
      String.pad_trailing(digits(c.id_no), 12) <>
      String.pad_trailing("", 12) <>
      "MY" <>
      zfill(to_cents(c.pcb_employee), 8) <>
      zfill(0, 8) <>
      String.pad_trailing("", 10)
  end

  defp to_cents(amount),
    do: dec(amount) |> Decimal.mult(100) |> Decimal.round(0) |> Decimal.to_integer()

  defp digits(nil), do: ""
  defp digits(s), do: String.replace(to_string(s), ~r/[^0-9]/, "")
  defp pad0(v, n), do: String.pad_leading(digits(v), n, "0")
  defp zfill(int, n), do: String.pad_leading(Integer.to_string(int), n, "0")
end
