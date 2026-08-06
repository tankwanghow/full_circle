defmodule FullCircle.CommandPalette.Types do
  @moduledoc false

  import FullCircle.Authorization
  alias FullCircle.CommandPalette.Hit

  # {doc_type, update_action, display_label, route_segment, print?}
  @type_specs [
    {"Invoice", :update_invoice, "Invoice", "Invoice", true},
    {"PurInvoice", :update_pur_invoice, "Purchase Invoice", "PurInvoice", false},
    {"Receipt", :update_receipt, "Receipt", "Receipt", true},
    {"Payment", :update_payment, "Payment", "Payment", true},
    {"CreditNote", :update_credit_note, "Credit Note", "CreditNote", true},
    {"DebitNote", :update_debit_note, "Debit Note", "DebitNote", true},
    {"Journal", :update_journal, "Journal", "Journal", true},
    {"Deposit", :update_deposit, "Deposit", "Deposit", false},
    {"ReturnCheque", :update_return_cheque, "Return Cheque", "ReturnCheque", true}
  ]

  # Create actions: compound tokens (no spaces)
  @create_specs [
    {~w(newinv newinvoice), "Invoice", :create_invoice, "New Invoice", "Invoice"},
    {~w(newpur newpinv newpurchase newpurinvoice), "PurInvoice", :create_pur_invoice,
     "New Purchase Invoice", "PurInvoice"},
    {~w(newrc newrec newreceipt), "Receipt", :create_receipt, "New Receipt", "Receipt"},
    {~w(newpv newpay newpayment), "Payment", :create_payment, "New Payment", "Payment"},
    {~w(newcn newcredit newcreditnote), "CreditNote", :create_credit_note, "New Credit Note",
     "CreditNote"},
    {~w(newdn newdebit newdebitnote), "DebitNote", :create_debit_note, "New Debit Note",
     "DebitNote"},
    {~w(newjs newjv newjournal), "Journal", :create_journal, "New Journal", "Journal"},
    {~w(newdep newdeposit newdeposits), "Deposit", :create_deposit, "New Deposit", "Deposit"},
    {~w(newrtn newreturn newreturncheque), "ReturnCheque", :create_return_cheque,
     "New Return Cheque", "ReturnCheque"}
  ]

  def min_length, do: 2
  def limit, do: 20
  def type_specs, do: @type_specs
  def create_specs, do: @create_specs

  def allowed_types(company, user) do
    for {doc_type, action, _label, _route, _print} <- @type_specs,
        can?(user, action, company),
        do: doc_type
  end

  def type_meta do
    Map.new(@type_specs, fn {t, _a, label, route, print?} ->
      {t, {label, route, print?}}
    end)
  end

  def to_hit(row, company_id, meta \\ type_meta()) do
    case Map.get(meta, row.doc_type) do
      {label, route_seg, print?} ->
        %Hit{
          kind: :document,
          doc_type: row.doc_type,
          doc_id: row.doc_id,
          doc_no: row.doc_no,
          doc_date: row.doc_date,
          contact_name: row.contact_name,
          good_name: Map.get(row, :good_name),
          bank_name: Map.get(row, :bank_name),
          label: label,
          path: "/companies/#{company_id}/#{route_seg}/#{row.doc_id}/edit",
          print_path:
            if(print?,
              do: "/companies/#{company_id}/#{route_seg}/#{row.doc_id}/print?pre_print=false",
              else: nil
            )
        }

      nil ->
        nil
    end
  end

  def escape_like(terms) do
    terms
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  def normalize_token(token) when is_binary(token) do
    token
    |> String.downcase()
    |> String.replace(~r/[^a-z]/, "")
  end

  @doc """
  True when the free-text query looks like a document number, not a person name.
  Used to skip noisy contact-master hits (e.g. INV-010798, RC00012).
  """
  def doc_number_like?(text) when is_binary(text) do
    t = String.trim(text)

    cond do
      t == "" ->
        false

      # Has digit and letter/dash pattern typical of doc nos
      Regex.match?(~r/\d/, t) and Regex.match?(~r/[A-Za-z\-]/, t) and not String.contains?(t, " ") ->
        true

      # Mostly digits (partial number)
      Regex.match?(~r/^\d{3,}$/, t) ->
        true

      # Known prefixes even without enough digits yet
      Regex.match?(
        ~r/^(inv|pinv|rc|pv|cn|dn|js|jv|dep|rtn|ret)[\-\d]*$/i,
        t
      ) ->
        true

      true ->
        false
    end
  end

  def doc_number_like?(_), do: false
end
