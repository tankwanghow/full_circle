defmodule FullCircle.EInvMetas.Prefill do
  @moduledoc """
  Seeds a local document from an LHDN e-invoice.

  * **Purchase** (`:purchase`, default) — supplier is the contact; used for
    received supplier Invoice → PurInvoice/Payment and sent self-billed → same.
  * **Sales** (`:sales`) — buyer/customer is the contact; used for received
    self-billed Invoice → Invoice/Receipt.

  Detail keys: `:pur_invoice_details`, `:payment_details`, `:invoice_details`,
  `:receipt_details`.
  """

  alias FullCircle.{DocPrefill, EInvMetas}
  use Gettext, backend: FullCircleWeb.Gettext

  @doc """
  Fetch, parse and seed.

  Options:
    * `:side` — `:purchase` (default) or `:sales`
  """
  def build(obj, com, user, detail_key, opts \\ []) do
    side = Keyword.get(opts, :side, :purchase)

    case side do
      :sales -> build_sales(obj, com, user, detail_key)
      _ -> build_purchase(obj, com, user, detail_key)
    end
  end

  defp build_purchase(obj, com, user, detail_key) do
    summary_tin = obj["supplierTIN"] || obj["issuerTIN"]
    summary_brn = if obj["issuerIDType"] == "BRN", do: obj["issuerID"]
    summary_name = obj["supplierName"] || obj["issuerName"]

    case EInvMetas.get_full_e_invoice(obj["uuid"], com, user) do
      {:ok, body} ->
        parsed = EInvMetas.parse_e_invoice_document(body)
        tin = parsed.supplier_tin || summary_tin
        brn = parsed.supplier_brn || summary_brn
        name = parsed.supplier_name || summary_name

        {attrs, warning} =
          %{
            detail_key => DocPrefill.seed_lines(parsed.invoice_lines),
            e_inv_internal_id: parsed.internal_id,
            e_inv_uuid: obj["uuid"]
          }
          |> DocPrefill.put_contact(tin, brn, name, com, :supplier)

        %{
          attrs: DocPrefill.put_goods(attrs, detail_key, com, user, :purchase),
          issue_date: parsed.issue_date,
          contact_ids: {tin, brn},
          # Keep old key for existing callers
          supplier_ids: {tin, brn},
          payable: payable(parsed.total_payable_amount, obj["totalPayableAmount"]),
          preview: {:ok, parsed},
          warnings: List.wrap(warning)
        }

      {:error, _reason} ->
        {attrs, warning} =
          %{e_inv_internal_id: obj["internalId"], e_inv_uuid: obj["uuid"]}
          |> DocPrefill.put_contact(summary_tin, summary_brn, summary_name, com, :supplier)

        %{
          attrs: attrs,
          issue_date: obj["dateTimeIssued"],
          contact_ids: {summary_tin, summary_brn},
          supplier_ids: {summary_tin, summary_brn},
          payable: payable(nil, obj["totalPayableAmount"]),
          preview: nil,
          warnings: [
            gettext("Could not fetch e-invoice details. Using summary data only.")
            | List.wrap(warning)
          ]
        }
    end
  end

  defp build_sales(obj, com, user, detail_key) do
    # Buyer issued the self-bill; they are our customer.
    summary_tin = obj["buyerTIN"] || obj["receiverTIN"] || obj["issuerTIN"]

    summary_brn =
      cond do
        obj["receiverIDType"] == "BRN" -> obj["receiverID"]
        obj["issuerIDType"] == "BRN" -> obj["issuerID"]
        true -> nil
      end

    summary_name = obj["buyerName"] || obj["receiverName"] || obj["issuerName"]

    case EInvMetas.get_full_e_invoice(obj["uuid"], com, user) do
      {:ok, body} ->
        parsed = EInvMetas.parse_e_invoice_document(body)
        tin = parsed.customer_tin || summary_tin
        brn = parsed.customer_brn || summary_brn
        name = parsed.customer_name || summary_name

        {attrs, warning} =
          %{
            detail_key => DocPrefill.seed_lines(parsed.invoice_lines),
            e_inv_internal_id: parsed.internal_id,
            e_inv_uuid: obj["uuid"]
          }
          |> DocPrefill.put_contact(tin, brn, name, com, :customer)

        %{
          attrs: DocPrefill.put_goods(attrs, detail_key, com, user, :sales),
          issue_date: parsed.issue_date,
          contact_ids: {tin, brn},
          supplier_ids: {tin, brn},
          payable: payable(parsed.total_payable_amount, obj["totalPayableAmount"]),
          preview: {:ok, parsed},
          warnings: List.wrap(warning)
        }

      {:error, _reason} ->
        {attrs, warning} =
          %{e_inv_internal_id: obj["internalId"], e_inv_uuid: obj["uuid"]}
          |> DocPrefill.put_contact(summary_tin, summary_brn, summary_name, com, :customer)

        %{
          attrs: attrs,
          issue_date: obj["dateTimeIssued"],
          contact_ids: {summary_tin, summary_brn},
          supplier_ids: {summary_tin, summary_brn},
          payable: payable(nil, obj["totalPayableAmount"]),
          preview: nil,
          warnings: [
            gettext("Could not fetch e-invoice details. Using summary data only.")
            | List.wrap(warning)
          ]
        }
    end
  end

  # --- Totals ---

  def variance(keyed_amount, payable) do
    diff = Decimal.sub(keyed_amount, payable)

    if Decimal.compare(Decimal.abs(diff), Decimal.new("0.01")) == :lt, do: nil, else: diff
  end

  defp payable(from_document, from_summary) do
    [from_document, from_summary]
    |> Enum.map(&DocPrefill.to_decimal/1)
    |> Enum.find(fn d -> d && Decimal.gt?(d, 0) end)
  end
end
