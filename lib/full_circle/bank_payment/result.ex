defmodule FullCircle.BankPayment.Result do
  @moduledoc """
  Reads a bank's result file with the format's "result" spec. Positions are
  1-based [from, length]. Only "fixed" layout for now (PB PSF, ECP guide §7);
  RHB's return file needs a "csv" layout once its sample is available.
  """

  @detail_fields ~w(record_id amount status reason)

  def validate(nil), do: []

  def validate(%{"layout" => "fixed"} = r) do
    header =
      case r["header"] do
        %{"identifier" => id, "filename" => pos} when is_binary(id) ->
          pos_errors("header filename", pos)

        _ ->
          ["result: header needs identifier and filename"]
      end

    detail =
      case r["detail"] do
        %{"identifier" => id} = d when is_binary(id) ->
          Enum.flat_map(@detail_fields, &pos_errors("detail #{&1}", d[&1]))

        _ ->
          ["result: detail needs identifier and positions"]
      end

    codes =
      for key <- ["success", "failure"],
          not (is_list(r[key]) and r[key] != [] and Enum.all?(r[key], &is_binary/1)),
          do: "result: #{key} must list the #{key} status codes"

    header ++ detail ++ codes
  end

  def validate(_), do: ["result: layout must be \"fixed\""]

  defp pos_errors(_name, [from, len])
       when is_integer(from) and from > 0 and is_integer(len) and len > 0, do: []

  defp pos_errors(name, _), do: ["result: #{name} must be [from, length]"]

  def parse(text, r) do
    lines = String.split(text, ~r/\r?\n/, trim: true)
    h = r["header"]
    d = r["detail"]

    case Enum.find(lines, &String.starts_with?(&1, h["identifier"])) do
      nil ->
        {:error, "no header line in the result file"}

      header ->
        details = Enum.filter(lines, &String.starts_with?(&1, d["identifier"]))

        {:ok,
         %{
           filename: header |> slice(h["filename"]) |> String.trim(),
           lines: Enum.map(details, &detail(&1, d, r))
         }}
    end
  end

  defp detail(line, d, r) do
    record_id = line |> slice(d["record_id"]) |> String.trim()
    status = line |> slice(d["status"]) |> String.trim()

    %{
      record_id: record_id,
      record_no:
        case Integer.parse(record_id) do
          {n, ""} -> n
          _ -> nil
        end,
      amount: amount(slice(line, d["amount"]), r["amount_in_cents"]),
      status: status,
      success: status in r["success"],
      failed: status in (r["failure"] || []),
      reason: line |> slice(d["reason"]) |> String.trim()
    }
  end

  defp slice(line, [from, len]), do: String.slice(line, from - 1, len) || ""

  # nil when the amount can't be read; the import reports it.
  defp amount(text, cents?) do
    text = String.trim(text)

    cond do
      text == "" ->
        nil

      cents? ->
        case Integer.parse(text) do
          {n, ""} -> n |> Decimal.new() |> Decimal.div(100) |> Decimal.round(2)
          _ -> nil
        end

      true ->
        case Decimal.parse(text) do
          {d, ""} -> d
          _ -> nil
        end
    end
  end

  @doc "PB's header holds 23 chars of the uploaded name, so compare without extension."
  def same_file?(a, b), do: normalize(a) != "" and normalize(a) == normalize(b)

  defp normalize(name),
    do: name |> to_string() |> String.trim() |> Path.rootname() |> String.downcase()
end
