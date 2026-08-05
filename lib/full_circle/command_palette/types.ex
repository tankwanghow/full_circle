defmodule FullCircle.CommandPalette.Types do
  @moduledoc false

  import FullCircle.Authorization
  alias FullCircle.CommandPalette.Hit

  # {doc_type, auth_action, display_label, route_segment}
  @type_specs [
    {"Invoice", :update_invoice, "Invoice", "Invoice"},
    {"PurInvoice", :update_pur_invoice, "Purchase Invoice", "PurInvoice"},
    {"Receipt", :update_receipt, "Receipt", "Receipt"},
    {"Payment", :update_payment, "Payment", "Payment"},
    {"CreditNote", :update_credit_note, "Credit Note", "CreditNote"},
    {"DebitNote", :update_debit_note, "Debit Note", "DebitNote"},
    {"Journal", :update_journal, "Journal", "Journal"}
  ]

  def min_length, do: 2
  def limit, do: 20
  def type_specs, do: @type_specs

  def allowed_types(company, user) do
    for {doc_type, action, _label, _route} <- @type_specs,
        can?(user, action, company),
        do: doc_type
  end

  def type_meta do
    Map.new(@type_specs, fn {t, _a, label, route} -> {t, {label, route}} end)
  end

  def to_hit(row, company_id, meta \\ type_meta()) do
    case Map.get(meta, row.doc_type) do
      {label, route_seg} ->
        %Hit{
          doc_type: row.doc_type,
          doc_id: row.doc_id,
          doc_no: row.doc_no,
          doc_date: row.doc_date,
          contact_name: row.contact_name,
          label: label,
          path: "/companies/#{company_id}/#{route_seg}/#{row.doc_id}/edit"
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
end
