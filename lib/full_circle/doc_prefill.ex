defmodule FullCircle.DocPrefill do
  @moduledoc """
  Seeding a new purchase or sales document from data read off another
  document: an LHDN e-invoice (`EInvMetas.Prefill`) or a photographed
  receipt (`Receipts.Prefill`). Contact by identifiers first, goods only when
  safe, and the seeded-line traps in one place — see
  `.claude/skills/e-invoice-bill-prefill.md`.
  """

  alias FullCircle.{Accounting, Billing, Product}
  use Gettext, backend: FullCircleWeb.Gettext

  # --- Lines ---

  @doc """
  Detail params from read lines. `tax_rate` on input is a percent; on output
  a fraction. `unit_multiplier` stays 0 and `package_qty` 0 until a good with
  packaging is applied — copying the good's multiplier zeroes the quantity.
  """
  def seed_lines(lines) do
    lines
    |> Enum.with_index()
    |> Enum.map(fn {line, idx} ->
      %{
        "_persistent_id" => idx,
        "descriptions" => line.descriptions,
        "quantity" => line.quantity,
        "unit_price" => line.unit_price,
        "discount" => line.discount,
        "tax_rate" => percent_to_fraction(line.tax_rate),
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

  defp percent_to_fraction(nil), do: 0
  defp percent_to_fraction(%Decimal{} = d), do: Decimal.div(d, 100)
  defp percent_to_fraction(n) when is_number(n), do: n / 100

  # --- Contact ---

  @doc """
  Resolves the contact by TIN, then BRN, then name. Returns `{attrs, warning}`;
  the warning is nil on an identifier match. `opts[:source]` names the
  document in the name-only warning (default "e-Invoice").
  """
  def put_contact(attrs, tin, brn, name, com, role, opts \\ []) do
    source = Keyword.get(opts, :source, gettext("e-Invoice"))

    case Accounting.resolve_e_invoice_contact(tin, brn, name, com) do
      nil ->
        label = if role == :customer, do: gettext("Customer"), else: gettext("Supplier")

        {Map.merge(attrs, %{contact_name: name || "", contact_id: nil, tax_id: nil, reg_no: nil}),
         gettext("%{role} \"%{name}\" not found. Please select the contact.",
           role: label,
           name: name || ""
         )}

      {contact, source_field} ->
        {Map.merge(attrs, %{
           contact_name: contact.name,
           contact_id: contact.id,
           tax_id: contact.tax_id,
           reg_no: contact.reg_no
         }), contact_warning(source_field, contact, name, role, source)}
    end
  end

  defp contact_warning(:name, contact, read_name, role, source) do
    role_label = if role == :customer, do: gettext("Customer"), else: gettext("Supplier")

    gettext(
      "%{role} matched by name only: %{source} \"%{read_name}\" to \"%{contact}\". No TIN or Reg No match, please verify.",
      role: role_label,
      source: source,
      read_name: read_name || "",
      contact: contact.name
    )
  end

  defp contact_warning(_identifier_match, _contact, _read_name, _role, _source), do: nil

  # --- Goods ---

  def put_goods(%{contact_id: contact_id} = attrs, detail_key, com, user, side)
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

  def put_goods(attrs, _detail_key, _com, _user, _side), do: attrs

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

  # --- Numbers ---

  def to_decimal(nil), do: nil
  def to_decimal(%Decimal{} = d), do: d
  def to_decimal(n) when is_integer(n), do: Decimal.new(n)
  def to_decimal(n) when is_float(n), do: Decimal.from_float(n)

  def to_decimal(s) when is_binary(s) do
    case Decimal.parse(s) do
      {d, _} -> d
      :error -> nil
    end
  end

  def to_decimal(_), do: nil
end
