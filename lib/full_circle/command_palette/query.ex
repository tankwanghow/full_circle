defmodule FullCircle.CommandPalette.Query do
  @moduledoc """
  Parse palette input into contact text, doc-type filters, and optional dates.

  Date rules:
  - **None** — no date filter
  - **One date** — documents on or before that date (`doc_date <= date`)
  - **Two dates** — inclusive range (order-independent)

  Examples:
    "INV-000012"
    "swee heng inv"
    "swee heng inv 5/2/2026"           → on or before 5/2/2026
    "swee heng inv 1/2/2026 - 14/2/2026" → range
    "inv 5/2/2026"                       → type + date only
  """

  defstruct raw: "",
            contact_terms: "",
            doc_types: nil,
            date_from: nil,
            date_to: nil,
            # :none | :on_or_before | :range
            date_mode: :none

  @type t :: %__MODULE__{
          raw: String.t(),
          contact_terms: String.t(),
          doc_types: [String.t()] | nil,
          date_from: Date.t() | nil,
          date_to: Date.t() | nil,
          date_mode: :none | :on_or_before | :range
        }

  # Whole-token type aliases (case-insensitive). Tokens with digits are never types
  # unless they fail date parse and look like pure type words (they won't with digits).
  @aliases %{
    "inv" => "Invoice",
    "invoice" => "Invoice",
    "invoices" => "Invoice",
    "pinv" => "PurInvoice",
    "pur" => "PurInvoice",
    "purchase" => "PurInvoice",
    "purchases" => "PurInvoice",
    "pinvoice" => "PurInvoice",
    "rc" => "Receipt",
    "receipt" => "Receipt",
    "receipts" => "Receipt",
    "rec" => "Receipt",
    "pv" => "Payment",
    "payment" => "Payment",
    "payments" => "Payment",
    "pay" => "Payment",
    "cn" => "CreditNote",
    "credit" => "CreditNote",
    "creditnote" => "CreditNote",
    "dn" => "DebitNote",
    "debit" => "DebitNote",
    "debitnote" => "DebitNote",
    "js" => "Journal",
    "jv" => "Journal",
    "journal" => "Journal",
    "journals" => "Journal"
  }

  @doc """
  Parse free text into a query struct.
  """
  def parse(text) when is_binary(text) do
    raw = String.trim(text)
    tokens = String.split(raw, ~r/\s+/, trim: true)

    {dates, non_date_tokens} = extract_dates(tokens)

    {type_tokens, other_tokens} = Enum.split_with(non_date_tokens, &type_token?/1)

    doc_types =
      type_tokens
      |> Enum.map(&Map.fetch!(@aliases, normalize(&1)))
      |> Enum.uniq()

    {date_mode, date_from, date_to} = date_fields(dates)

    %__MODULE__{
      raw: raw,
      contact_terms: Enum.join(other_tokens, " "),
      doc_types: if(doc_types == [], do: nil, else: doc_types),
      date_from: date_from,
      date_to: date_to,
      date_mode: date_mode
    }
  end

  def parse(_), do: parse("")

  # --- dates -----------------------------------------------------------------

  # Pull date-like tokens and "d1 - d2" pairs. Separator "-" alone is skipped.
  defp extract_dates(tokens) do
    {dates, rest, _pending_sep} =
      Enum.reduce(tokens, {[], [], false}, fn token, {dates, rest, after_sep} ->
        cond do
          date_separator?(token) ->
            {dates, rest, true}

          parse_date(token) != :error ->
            {:ok, d} = parse_date(token)
            {dates ++ [d], rest, false}

          true ->
            # If we had a dangling "-", keep it out of contact terms
            _ = after_sep
            {dates, rest ++ [token], false}
        end
      end)

    {dates, rest}
  end

  defp date_separator?(token) do
    token in ["-", "–", "—", "..", "to", "TO"]
  end

  defp date_fields([]), do: {:none, nil, nil}

  defp date_fields([d]) do
    # Single date → on or before (doc_date <= d)
    {:on_or_before, nil, d}
  end

  defp date_fields([d1, d2 | _]) do
    if Date.compare(d1, d2) == :gt do
      {:range, d2, d1}
    else
      {:range, d1, d2}
    end
  end

  @doc false
  def parse_date(token) when is_binary(token) do
    token = String.trim(token)

    cond do
      # d/m/yyyy or d-m-yyyy or d.m.yyyy
      Regex.match?(~r/^\d{1,2}[\/\-\.]\d{1,2}[\/\-\.]\d{4}$/, token) ->
        [a, b, y] = Regex.run(~r/^(\d{1,2})[\/\-\.](\d{1,2})[\/\-\.](\d{4})$/, token, capture: :all_but_first)
        # Prefer DMY (Malaysia): day/month/year
        try_date(y, b, a) || try_date(y, a, b)

      # yyyy-mm-dd (ISO)
      Regex.match?(~r/^\d{4}-\d{2}-\d{2}$/, token) ->
        case Date.from_iso8601(token) do
          {:ok, d} -> {:ok, d}
          _ -> :error
        end

      true ->
        :error
    end
  end

  defp try_date(y, m, d) do
    y = String.to_integer(y)
    m = String.to_integer(m)
    d = String.to_integer(d)

    case Date.new(y, m, d) do
      {:ok, date} -> {:ok, date}
      _ -> nil
    end
  end

  # --- types -----------------------------------------------------------------

  defp type_token?(token) do
    if Regex.match?(~r/\d/, token) do
      false
    else
      Map.has_key?(@aliases, normalize(token))
    end
  end

  defp normalize(token) do
    token
    |> String.downcase()
    |> String.replace(~r/[^a-z]/, "")
  end
end
