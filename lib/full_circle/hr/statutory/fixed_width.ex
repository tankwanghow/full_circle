defmodule FullCircle.HR.Statutory.FixedWidth do
  @moduledoc "Padding/number helpers shared by the fixed-width statutory formatters."

  def dec(%Decimal{} = d), do: d
  def dec(nil), do: Decimal.new(0)
  def dec(n), do: Decimal.new("#{n}")

  def add(a, b), do: Decimal.add(dec(a), dec(b))
  def pos?(v), do: Decimal.gt?(dec(v), 0)

  # SOCSO/EIS legacy: id_number = socso_no, falling back to id_no when blank/"-"/null.
  def idnum(%{socso_no: s, id_no: id}) do
    case s do
      nil -> id
      "" -> id
      "-" -> id
      v -> v
    end
  end

  def pad_t(str, n), do: String.pad_trailing(to_string(str), n)

  # to_char(month,'00') |> trim  -> 2-digit zero-padded
  def two(n), do: String.pad_leading("#{n}", 2, "0")
  def four(n), do: String.pad_leading("#{n}", 4, "0")

  # to_char(amount*100,'0...0') |> trim : amount in cents, zero-padded to width.
  def cents(amount, width) do
    cents = dec(amount) |> Decimal.mult(100) |> Decimal.round(0) |> Decimal.to_integer()
    String.pad_leading(Integer.to_string(cents), width, "0")
  end
end
