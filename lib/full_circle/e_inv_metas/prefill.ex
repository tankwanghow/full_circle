defmodule FullCircle.EInvMetas.Prefill do
  @moduledoc """
  Seeds a purchase document from a received LHDN e-invoice.

  Shared by `PurInvoiceLive.Form` and `PaymentLive.Form`, which record the same
  event — a supplier billed us — as different documents. `PaymentDetail` is
  field-identical to `PurInvoiceDetail`, so every seeding rule and every trap
  below applies unchanged to both. Keeping one implementation matters more than
  usual here: the traps are silent, so a divergent copy would not fail loudly.

  See `.claude/skills/e-invoice-bill-prefill.md` for the measurements behind
  each rule.
  """

  alias FullCircle.{Accounting, Billing, Product, EInvMetas}
  use Gettext, backend: FullCircleWeb.Gettext

  @doc """
  Fetch, parse and seed. Returns a map of:

    * `:attrs` — document-independent changeset attrs: contact, the display-only
      `tax_id`/`reg_no` mirrors, `e_inv_uuid`, `e_inv_internal_id`, and the
      seeded detail lines under `detail_key`
    * `:issue_date` — the caller maps this onto its own date fields
    * `:supplier_ids` — `{tin, brn}`, to learn onto the contact after saving
    * `:payable` — the amount LHDN says is payable, or nil if there is none
    * `:preview` — the parsed document for display, or nil if the fetch failed
    * `:warnings` — messages to flash

  `detail_key` is `:pur_invoice_details` or `:payment_details`.
  """
  def build(obj, com, user, detail_key) do
    summary_tin = obj["supplierTIN"] || obj["issuerTIN"]
    summary_brn = if obj["issuerIDType"] == "BRN", do: obj["issuerID"]

    case EInvMetas.get_full_e_invoice(obj["uuid"], com, user) do
      {:ok, body} ->
        parsed = EInvMetas.parse_e_invoice_document(body)
        tin = parsed.supplier_tin || summary_tin
        brn = parsed.supplier_brn || summary_brn

        {attrs, warning} =
          %{
            detail_key => seed_lines(parsed.invoice_lines),
            e_inv_internal_id: parsed.internal_id,
            e_inv_uuid: obj["uuid"]
          }
          |> put_supplier(tin, brn, parsed.supplier_name, com)

        %{
          attrs: put_goods(attrs, detail_key, com, user),
          issue_date: parsed.issue_date,
          supplier_ids: {tin, brn},
          payable: payable(parsed.total_payable_amount, obj["totalPayableAmount"]),
          # The document we just fetched — showing it costs no extra LHDN call.
          preview: {:ok, parsed},
          warnings: List.wrap(warning)
        }

      {:error, _reason} ->
        {attrs, warning} =
          %{e_inv_internal_id: obj["internalId"], e_inv_uuid: obj["uuid"]}
          |> put_supplier(summary_tin, summary_brn, obj["supplierName"], com)

        %{
          attrs: attrs,
          issue_date: obj["dateTimeIssued"],
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
        # LHDN reports the tax as a percentage ("5.0"); tax_rate here is a
        # fraction, the same scale as tax_codes.rate (0.06 for 6%).
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

  # --- Supplier ---

  # tax_id and reg_no are display-only virtuals mirroring the contact, the same
  # ones assign_autocomplete_ids/5 fills when a contact is picked by hand.
  # Returns {attrs, warning}.
  defp put_supplier(attrs, tin, brn, name, com) do
    case Accounting.resolve_e_invoice_contact(tin, brn, name, com) do
      nil ->
        {Map.merge(attrs, %{contact_name: name || "", contact_id: nil, tax_id: nil, reg_no: nil}),
         gettext("Supplier \"%{name}\" not found. Please select the contact.", name: name || "")}

      {contact, source} ->
        {Map.merge(attrs, %{
           contact_name: contact.name,
           contact_id: contact.id,
           tax_id: contact.tax_id,
           reg_no: contact.reg_no
         }), supplier_warning(source, contact, name)}
    end
  end

  # A TIN or Reg No match identifies the supplier outright. A name match does
  # not, so say so — the user should confirm it before saving.
  defp supplier_warning(:name, contact, e_inv_name) do
    gettext(
      "Supplier matched by name only: e-Invoice \"%{e_inv_name}\" to \"%{contact}\". No TIN or Reg No match, please verify.",
      e_inv_name: e_inv_name || "",
      contact: contact.name
    )
  end

  defp supplier_warning(_identifier_match, _contact, _e_inv_name), do: nil

  # --- Goods ---

  defp put_goods(%{contact_id: contact_id} = attrs, detail_key, com, user)
       when not is_nil(contact_id) do
    details = Map.get(attrs, detail_key)

    if is_list(details) do
      case Billing.purchased_good_names(contact_id, com) do
        [] ->
          attrs

        names ->
          sole? = match?([_], names)
          Map.put(attrs, detail_key, Enum.map(details, &seed_good(&1, names, sole?, com, user)))
      end
    else
      attrs
    end
  end

  defp put_goods(attrs, _detail_key, _com, _user), do: attrs

  # Two ways to know the good, in order of confidence:
  #
  #   * the supplier has only ever sold one good (98% right) — take it, and take
  #     its packaging too, which is right 93% of the time;
  #   * otherwise the line's own description names one of the goods we have
  #     bought from them before (96% right) — take the good but NOT the
  #     packaging. The description tells us the product, never the pack size,
  #     and a good's first packaging is often not the one this supplier uses
  #     (Wheat Pollard defaults to "Unweighted Bag" while every real bill used
  #     "55kg/Bag"), so leave it blank for the user to choose.
  defp seed_good(detail, names, true = _sole?, com, user) do
    apply_good(detail, hd(names), com, user, packaging: true)
  end

  defp seed_good(detail, names, false = _sole?, com, user) do
    case good_named_in(detail["descriptions"], names) do
      nil -> detail
      name -> apply_good(detail, name, com, user, packaging: false)
    end
  end

  # Longest match wins, so "Wheat Brans" never shadows "Wheat Pollard".
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
      good -> merge_good(detail, good, opts[:packaging])
    end
  end

  defp merge_good(detail, good, packaging?) do
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
      # unit_multiplier stays 0 on purpose. compute_detail_fields/1 uses
      # package_qty * unit_multiplier whenever the multiplier is positive, which
      # would throw away the quantity LHDN gave us and leave the line at zero.
      "unit_multiplier" => 0,
      # The quantity LHDN sends is in the supplier's own units, which for a
      # bagged good is bags, not the good's stock unit ("WHEAT POLLARD 55KG",
      # qty 550 = 550 bags = 30.25 Mt). Seed it into both fields: quantity is
      # used while no packaging is set, and the moment the user picks a
      # packaging with a multiplier, compute_detail_fields/1 switches to
      # package_qty * multiplier and the line completes without retyping.
      "package_qty" => detail["quantity"]
    })
    |> Map.merge(packaging)
  end

  # --- Totals ---

  @doc """
  Difference between what has been keyed and what the supplier declared to
  LHDN. `nil` when they agree, so callers can stay quiet.
  """
  def variance(keyed_amount, payable) do
    diff = Decimal.sub(keyed_amount, payable)

    if Decimal.compare(Decimal.abs(diff), Decimal.new("0.01")) == :lt, do: nil, else: diff
  end

  # The amount LHDN says is payable, used as the target the keyed lines must add
  # up to. Some suppliers publish a summary total of 0 even on a real invoice, so
  # treat zero as "no figure to compare against" rather than as a discrepancy.
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
