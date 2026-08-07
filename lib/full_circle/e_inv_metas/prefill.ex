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

  alias FullCircle.{Accounting, Billing, Product, EInvMetas}
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
            detail_key => seed_lines(parsed.invoice_lines),
            e_inv_internal_id: parsed.internal_id,
            e_inv_uuid: obj["uuid"]
          }
          |> put_contact(tin, brn, name, com, :supplier)

        %{
          attrs: put_goods(attrs, detail_key, com, user, :purchase),
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
          |> put_contact(summary_tin, summary_brn, summary_name, com, :supplier)

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
            detail_key => seed_lines(parsed.invoice_lines),
            e_inv_internal_id: parsed.internal_id,
            e_inv_uuid: obj["uuid"]
          }
          |> put_contact(tin, brn, name, com, :customer)

        %{
          attrs: put_goods(attrs, detail_key, com, user, :sales),
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
          |> put_contact(summary_tin, summary_brn, summary_name, com, :customer)

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

  defp seed_lines(invoice_lines) do
    invoice_lines
    |> Enum.with_index()
    |> Enum.map(fn {line, idx} ->
      %{
        "_persistent_id" => idx,
        "descriptions" => line.descriptions,
        "quantity" => line.quantity,
        "unit_price" => line.unit_price,
        "discount" => line.discount,
        "tax_rate" => (line.tax_rate || 0) / 100,
        "good_name" => "",
        "account_name" => "",
        "tax_code_name" => "",
        "package_name" => "",
        "package_qty" => 0,
        "unit_multiplier" => 0,
        "unit" => ""
      }
    end)
  end

  # --- Contact ---

  defp put_contact(attrs, tin, brn, name, com, role) do
    case Accounting.resolve_e_invoice_contact(tin, brn, name, com) do
      nil ->
        label = if role == :customer, do: gettext("Customer"), else: gettext("Supplier")

        {Map.merge(attrs, %{contact_name: name || "", contact_id: nil, tax_id: nil, reg_no: nil}),
         gettext("%{role} \"%{name}\" not found. Please select the contact.",
           role: label,
           name: name || ""
         )}

      {contact, source} ->
        {Map.merge(attrs, %{
           contact_name: contact.name,
           contact_id: contact.id,
           tax_id: contact.tax_id,
           reg_no: contact.reg_no
         }), contact_warning(source, contact, name, role)}
    end
  end

  defp contact_warning(:name, contact, e_inv_name, role) do
    role_label = if role == :customer, do: gettext("Customer"), else: gettext("Supplier")

    gettext(
      "%{role} matched by name only: e-Invoice \"%{e_inv_name}\" to \"%{contact}\". No TIN or Reg No match, please verify.",
      role: role_label,
      e_inv_name: e_inv_name || "",
      contact: contact.name
    )
  end

  defp contact_warning(_identifier_match, _contact, _e_inv_name, _role), do: nil

  # --- Goods ---

  defp put_goods(%{contact_id: contact_id} = attrs, detail_key, com, user, side)
       when not is_nil(contact_id) do
    details = Map.get(attrs, detail_key)

    if is_list(details) do
      names =
        case side do
          :sales -> Billing.sold_good_names(contact_id, com)
          _ -> Billing.purchased_good_names(contact_id, com)
        end

      case names do
        [] ->
          attrs

        names ->
          sole? = match?([_], names)

          Map.put(
            attrs,
            detail_key,
            Enum.map(details, &seed_good(&1, names, sole?, com, user, side))
          )
      end
    else
      attrs
    end
  end

  defp put_goods(attrs, _detail_key, _com, _user, _side), do: attrs

  defp seed_good(detail, names, true = _sole?, com, user, side) do
    apply_good(detail, hd(names), com, user, packaging: true, side: side)
  end

  defp seed_good(detail, names, false = _sole?, com, user, side) do
    case good_named_in(detail["descriptions"], names) do
      nil -> detail
      name -> apply_good(detail, name, com, user, packaging: false, side: side)
    end
  end

  defp good_named_in(descriptions, names) when is_binary(descriptions) and descriptions != "" do
    descr = String.downcase(descriptions)

    names
    |> Enum.filter(&String.contains?(descr, String.downcase(&1)))
    |> Enum.max_by(&String.length/1, fn -> nil end)
  end

  defp good_named_in(_descriptions, _names), do: nil

  defp apply_good(detail, name, com, user, opts) do
    case Product.get_good_by_name(name, com, user) do
      nil -> detail
      good -> merge_good(detail, good, opts[:packaging], opts[:side] || :purchase)
    end
  end

  defp merge_good(detail, good, packaging?, :sales) do
    packaging =
      if packaging?,
        do: %{"package_name" => good.package_name, "package_id" => good.package_id},
        else: %{"package_name" => "", "package_id" => nil}

    detail
    |> Map.merge(%{
      "good_name" => good.value,
      "good_id" => good.id,
      "account_name" => good.sales_account_name,
      "account_id" => good.sales_account_id,
      "tax_code_name" => good.sales_tax_code_name,
      "tax_code_id" => good.sales_tax_code_id,
      "tax_rate" => good.sales_tax_rate,
      "unit" => good.unit,
      "unit_multiplier" => 0,
      "package_qty" => detail["quantity"]
    })
    |> Map.merge(packaging)
  end

  defp merge_good(detail, good, packaging?, _purchase) do
    packaging =
      if packaging?,
        do: %{"package_name" => good.package_name, "package_id" => good.package_id},
        else: %{"package_name" => "", "package_id" => nil}

    detail
    |> Map.merge(%{
      "good_name" => good.value,
      "good_id" => good.id,
      "account_name" => good.purchase_account_name,
      "account_id" => good.purchase_account_id,
      "tax_code_name" => good.purchase_tax_code_name,
      "tax_code_id" => good.purchase_tax_code_id,
      "tax_rate" => good.purchase_tax_rate,
      "unit" => good.unit,
      "unit_multiplier" => 0,
      "package_qty" => detail["quantity"]
    })
    |> Map.merge(packaging)
  end

  # --- Totals ---

  def variance(keyed_amount, payable) do
    diff = Decimal.sub(keyed_amount, payable)

    if Decimal.compare(Decimal.abs(diff), Decimal.new("0.01")) == :lt, do: nil, else: diff
  end

  defp payable(from_document, from_summary) do
    [from_document, from_summary]
    |> Enum.map(&to_decimal/1)
    |> Enum.find(fn d -> d && Decimal.gt?(d, 0) end)
  end

  defp to_decimal(nil), do: nil
  defp to_decimal(%Decimal{} = d), do: d
  defp to_decimal(n) when is_integer(n), do: Decimal.new(n)
  defp to_decimal(n) when is_float(n), do: Decimal.from_float(n)

  defp to_decimal(s) when is_binary(s) do
    case Decimal.parse(s) do
      {d, _} -> d
      :error -> nil
    end
  end

  defp to_decimal(_), do: nil
end
