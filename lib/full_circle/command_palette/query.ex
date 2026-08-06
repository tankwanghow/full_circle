defmodule FullCircle.CommandPalette.Query do
  @moduledoc """
  Parse palette input into contact text, doc-type filters, dates, and optional good name.

  Date rules:
  - **None** — no date filter
  - **One date** — on or before (`doc_date <= date`)
  - **Two dates** — inclusive range

  Good name (line filter on Invoice / PurInvoice):
  - Explicit: `swee heng good grade e` (token `good` separates contact from good)
  - Or suffix that matches a company good: `swee heng grade e`
  """

  import Ecto.Query, warn: false

  alias FullCircle.Repo
  alias FullCircle.Sys
  alias FullCircle.Product.Good
  alias FullCircle.CommandPalette.Types

  defstruct raw: "",
            contact_terms: "",
            good_terms: nil,
            bank_terms: nil,
            funds_terms: nil,
            doc_types: nil,
            date_from: nil,
            date_to: nil,
            date_mode: :none

  @type t :: %__MODULE__{
          raw: String.t(),
          contact_terms: String.t(),
          good_terms: String.t() | nil,
          bank_terms: String.t() | nil,
          funds_terms: String.t() | nil,
          doc_types: [String.t()] | nil,
          date_from: Date.t() | nil,
          date_to: Date.t() | nil,
          date_mode: :none | :on_or_before | :range
        }

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
    "journals" => "Journal",
    "dep" => "Deposit",
    "deposit" => "Deposit",
    "deposits" => "Deposit",
    "rtn" => "ReturnCheque",
    "return" => "ReturnCheque",
    "returncheque" => "ReturnCheque",
    "returns" => "ReturnCheque"
  }

  @doc """
  Parse free text (company-agnostic). Call `resolve_good/3` after for line filters.
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

    # Explicit separators (not type keywords)
    {contact_terms, good_terms} = split_explicit_keyword(other_tokens, "good")

    {contact_terms, bank_terms} =
      split_explicit_keyword(String.split(contact_terms, ~r/\s+/, trim: true), "bank")

    {contact_terms, funds_terms} =
      split_explicit_keyword(String.split(contact_terms, ~r/\s+/, trim: true), "funds")

    %__MODULE__{
      raw: raw,
      contact_terms: contact_terms,
      good_terms: good_terms,
      bank_terms: bank_terms,
      funds_terms: funds_terms,
      doc_types: if(doc_types == [], do: nil, else: doc_types),
      date_from: date_from,
      date_to: date_to,
      date_mode: date_mode
    }
  end

  def parse(_), do: parse("")

  @doc """
  If no explicit good was set, try matching a suffix of contact_terms to a company good.
  """
  def resolve_good(%__MODULE__{good_terms: g} = q, _company, _user)
      when is_binary(g) and g != "" do
    q
  end

  def resolve_good(%__MODULE__{} = q, company, user) do
    tokens = String.split(q.contact_terms, ~r/\s+/, trim: true)

    case best_good_suffix(company, user, tokens) do
      {contact, good} ->
        %{q | contact_terms: contact, good_terms: good}

      :none ->
        q
    end
  end

  # --- good split ------------------------------------------------------------

  # tokens may be a list or we re-split contact string above for bank
  defp split_explicit_keyword(tokens, keyword) when is_list(tokens) do
    case Enum.split_while(tokens, &(normalize(&1) != keyword)) do
      {before, [kw | after_kw]} when after_kw != [] ->
        _ = kw
        {Enum.join(before, " "), Enum.join(after_kw, " ")}

      _ ->
        {Enum.join(tokens, " "), nil}
    end
  end

  defp best_good_suffix(_company, _user, []), do: :none
  defp best_good_suffix(_company, _user, [_single]), do: :none

  defp best_good_suffix(company, user, tokens) do
    n = length(tokens)
    # Prefer longer good suffixes (up to 4 words), require remaining contact >= 2 chars if any
    1..min(n - 1, 4)
    |> Enum.reverse()
    |> Enum.find_value(:none, fn good_len ->
      contact_toks = Enum.take(tokens, n - good_len)
      good_toks = Enum.take(tokens, -good_len)
      good_terms = Enum.join(good_toks, " ")
      contact_terms = Enum.join(contact_toks, " ")

      if goods_match?(company, user, good_terms) and
           (contact_terms == "" or String.length(contact_terms) >= Types.min_length()) do
        {contact_terms, good_terms}
      else
        nil
      end
    end)
  end

  defp goods_match?(company, user, terms) do
    pattern = "%#{Types.escape_like(terms)}%"

    from(g in Good,
      join: com in subquery(Sys.user_company(company, user)),
      on: com.id == g.company_id,
      where: ilike(g.name, ^pattern),
      limit: 1,
      select: g.id
    )
    |> Repo.one()
    |> is_binary()
  end

  # --- dates -----------------------------------------------------------------

  defp extract_dates(tokens) do
    {dates, rest, _pending_sep} =
      Enum.reduce(tokens, {[], [], false}, fn token, {dates, rest, _after_sep} ->
        cond do
          date_separator?(token) ->
            {dates, rest, true}

          parse_date(token) != :error ->
            {:ok, d} = parse_date(token)
            {dates ++ [d], rest, false}

          true ->
            {dates, rest ++ [token], false}
        end
      end)

    {dates, rest}
  end

  defp date_separator?(token) do
    token in ["-", "–", "—", "..", "to", "TO"]
  end

  defp date_fields([]), do: {:none, nil, nil}
  defp date_fields([d]), do: {:on_or_before, nil, d}

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
      Regex.match?(~r/^\d{1,2}[\/\-\.]\d{1,2}[\/\-\.]\d{4}$/, token) ->
        [a, b, y] =
          Regex.run(~r/^(\d{1,2})[\/\-\.](\d{1,2})[\/\-\.](\d{4})$/, token, capture: :all_but_first)

        try_date(y, b, a) || try_date(y, a, b) || :error

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
    case Date.new(String.to_integer(y), String.to_integer(m), String.to_integer(d)) do
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
