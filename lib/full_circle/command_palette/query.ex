defmodule FullCircle.CommandPalette.Query do
  @moduledoc """
  Lightweight parse of palette input into contact text + optional doc-type filters.

  Examples:
    "INV-000012"           → contact "", types nil, raw as-is (doc-no search)
    "swee heng"            → contact "swee heng"
    "swee heng inv"        → contact "swee heng", types ["Invoice"]
    "inv swee heng"        → same
    "inv"                  → contact "", types ["Invoice"] (doc-no still uses raw)
  """

  defstruct raw: "", contact_terms: "", doc_types: nil

  @type t :: %__MODULE__{
          raw: String.t(),
          contact_terms: String.t(),
          doc_types: [String.t()] | nil
        }

  # Whole-token aliases only (case-insensitive). Tokens with digits are never types.
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

    {type_tokens, other_tokens} = Enum.split_with(tokens, &type_token?/1)

    doc_types =
      type_tokens
      |> Enum.map(&Map.fetch!(@aliases, normalize(&1)))
      |> Enum.uniq()

    %__MODULE__{
      raw: raw,
      contact_terms: Enum.join(other_tokens, " "),
      doc_types: if(doc_types == [], do: nil, else: doc_types)
    }
  end

  def parse(_), do: parse("")

  # Tokens with digits are doc numbers (INV-000012), never type aliases.
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
