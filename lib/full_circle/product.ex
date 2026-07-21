defmodule FullCircle.Product do
  import Ecto.Query, warn: false
  import FullCircle.Helpers
  use Gettext, backend: FullCircleWeb.Gettext

  alias FullCircle.Accounting.{Account, TaxCode}

  alias FullCircle.Product.{
    Good,
    Packaging
  }

  alias FullCircle.{Repo, Sys}

  def categories() do
    ~w{Egg Chicken Pig Dung Feed FFB Vaccine Additive Others}
  end

  # GOODS

  @doc """
  Counts document/trading rows that store quantity for this good.
  Used to warn when changing the good's unit (legacy qty would be misinterpreted).
  """
  def quantity_line_usage(good_id) when is_binary(good_id) do
    counts = %{
      invoice_details: count_by_good(FullCircle.Billing.InvoiceDetail, good_id),
      pur_invoice_details: count_by_good(FullCircle.Billing.PurInvoiceDetail, good_id),
      receipt_details: count_by_good(FullCircle.ReceiveFund.ReceiptDetail, good_id),
      payment_details: count_by_good(FullCircle.BillPay.PaymentDetail, good_id),
      trading_supply_positions:
        count_by_good_if_loaded(FullCircle.Trading.SupplyPosition, good_id),
      trading_sales_positions: count_by_good_if_loaded(FullCircle.Trading.SalesPosition, good_id)
    }

    total =
      counts
      |> Map.values()
      |> Enum.sum()

    Map.put(counts, :total, total)
  end

  def quantity_line_usage(_), do: %{total: 0}

  @doc """
  True when unit would change and the good already has qty lines referencing it.
  """
  def unit_change_risk?(good_id, old_unit, new_unit) when is_binary(good_id) do
    old_u = old_unit |> to_string() |> String.trim()
    new_u = new_unit |> to_string() |> String.trim()
    old_u != new_u and new_u != "" and quantity_line_usage(good_id).total > 0
  end

  def unit_change_risk?(_, _, _), do: false

  def unit_change_warning_message(good_id) when is_binary(good_id) do
    usage = quantity_line_usage(good_id)

    if usage.total == 0 do
      nil
    else
      parts =
        [
          {usage.invoice_details, gettext("invoice lines")},
          {usage.pur_invoice_details, gettext("purchase invoice lines")},
          {usage.receipt_details, gettext("receipt lines")},
          {usage.payment_details, gettext("payment lines")},
          {usage.trading_supply_positions, gettext("trading supply positions")},
          {usage.trading_sales_positions, gettext("trading sales positions")}
        ]
        |> Enum.filter(fn {n, _} -> n > 0 end)
        |> Enum.map(fn {n, label} -> "#{n} #{label}" end)
        |> Enum.join(", ")

      gettext(
        "Warning: this good already has quantity data (%{parts}). Changing the unit can make existing quantities wrong or misleading. Prefer creating a new good if the unit really changed.",
        parts: parts
      )
    end
  end

  def unit_change_warning_message(_), do: nil

  @doc """
  Counts document lines that reference a packaging (package_id).
  Used to warn when changing packaging unit_multiplier.
  """
  def packaging_line_usage(package_id) when is_binary(package_id) do
    counts = %{
      invoice_details: count_by_package(FullCircle.Billing.InvoiceDetail, package_id),
      pur_invoice_details: count_by_package(FullCircle.Billing.PurInvoiceDetail, package_id),
      receipt_details: count_by_package(FullCircle.ReceiveFund.ReceiptDetail, package_id),
      payment_details: count_by_package(FullCircle.BillPay.PaymentDetail, package_id)
    }

    total = counts |> Map.values() |> Enum.sum()
    Map.put(counts, :total, total)
  end

  def packaging_line_usage(_), do: %{total: 0}

  def packaging_unit_multiplier_change_risk?(package_id, old_mult, new_mult)
      when is_binary(package_id) do
    decimal_changed?(old_mult, new_mult) and packaging_line_usage(package_id).total > 0
  end

  def packaging_unit_multiplier_change_risk?(_, _, _), do: false

  def packaging_unit_multiplier_warning_message(package_id, package_name \\ nil)

  def packaging_unit_multiplier_warning_message(package_id, package_name)
      when is_binary(package_id) do
    usage = packaging_line_usage(package_id)

    if usage.total == 0 do
      nil
    else
      parts =
        [
          {usage.invoice_details, gettext("invoice lines")},
          {usage.pur_invoice_details, gettext("purchase invoice lines")},
          {usage.receipt_details, gettext("receipt lines")},
          {usage.payment_details, gettext("payment lines")}
        ]
        |> Enum.filter(fn {n, _} -> n > 0 end)
        |> Enum.map(fn {n, label} -> "#{n} #{label}" end)
        |> Enum.join(", ")

      name = package_name || gettext("this packaging")

      gettext(
        "Warning: packaging \"%{name}\" is already used on quantity lines (%{parts}). Changing unit multiplier can make existing package quantities wrong. Prefer a new packaging if the multiplier really changed.",
        name: name,
        parts: parts
      )
    end
  end

  def packaging_unit_multiplier_warning_message(_, _), do: nil

  @doc """
  Warnings for packagings whose unit_multiplier changed vs original and are already referenced.
  `original_packagings` is the list of %Packaging{} currently stored; `params_packagings` is the form map.
  """
  def packaging_multiplier_change_warnings(original_packagings, params_packagings)
      when is_list(original_packagings) and is_map(params_packagings) do
    originals = Map.new(original_packagings, fn p -> {p.id, p} end)

    params_packagings
    |> Enum.flat_map(fn {_idx, p} ->
      id = p["id"] || p[:id]
      name = p["name"] || p[:name]
      new_mult = p["unit_multiplier"] || p[:unit_multiplier]

      cond do
        not is_binary(id) or id == "" ->
          []

        match?(%{id: ^id}, originals[id]) == false and is_nil(originals[id]) ->
          []

        true ->
          old = originals[id]

          if packaging_unit_multiplier_change_risk?(id, old.unit_multiplier, new_mult) do
            case packaging_unit_multiplier_warning_message(id, name || old.name) do
              nil -> []
              msg -> [msg]
            end
          else
            []
          end
      end
    end)
  end

  def packaging_multiplier_change_warnings(_, _), do: []

  defp decimal_changed?(old, new) do
    old_d = to_decimal(old)
    new_d = to_decimal(new)
    old_d != nil and new_d != nil and not Decimal.eq?(old_d, new_d)
  end

  defp to_decimal(%Decimal{} = d), do: d
  defp to_decimal(nil), do: nil
  defp to_decimal(""), do: nil

  defp to_decimal(v) when is_binary(v) do
    case Decimal.parse(v) do
      {d, _} -> d
      :error -> nil
    end
  end

  defp to_decimal(v) when is_integer(v), do: Decimal.new(v)
  defp to_decimal(v) when is_float(v), do: Decimal.from_float(v)
  defp to_decimal(_), do: nil

  defp count_by_good(schema, good_id) do
    from(r in schema, where: r.good_id == ^good_id, select: count(r.id))
    |> Repo.one()
    |> Kernel.||(0)
  rescue
    _ -> 0
  end

  defp count_by_package(schema, package_id) do
    from(r in schema, where: r.package_id == ^package_id, select: count(r.id))
    |> Repo.one()
    |> Kernel.||(0)
  rescue
    _ -> 0
  end

  defp count_by_good_if_loaded(mod, good_id) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, :__schema__, 1) do
      count_by_good(mod, good_id)
    else
      0
    end
  end

  def get_good!(id, company, user) do
    from(good in subquery(good_query(company, user)),
      preload: :packagings,
      where: good.id == ^id
    )
    |> Repo.one!()
  end

  def get_goods_by_category(cat, com, user) do
    from(good in subquery(good_query(com, user)),
      where: good.category == ^cat,
      select: %{
        id: good.id,
        name: good.name
      },
      order_by: good.name
    )
    |> Repo.all()
  end

  def get_good_by_name(name, company, user) do
    name = name |> String.trim()

    from(good in subquery(good_query(company, user)),
      left_join: pack in Packaging,
      on: pack.good_id == good.id,
      where: good.name == ^name,
      select: %{
        id: good.id,
        value: good.name,
        unit: good.unit,
        package_name: pack.name,
        package_id: pack.id,
        unit_multiplier: pack.unit_multiplier,
        sales_account_name: good.sales_account_name,
        purchase_account_name: good.purchase_account_name,
        sales_account_id: good.sales_account_id,
        purchase_account_id: good.purchase_account_id,
        sales_tax_code_name: good.sales_tax_code_name,
        purchase_tax_code_name: good.purchase_tax_code_name,
        sales_tax_code_id: good.sales_tax_code_id,
        purchase_tax_code_id: good.purchase_tax_code_id,
        sales_tax_rate: good.sales_tax_rate,
        purchase_tax_rate: good.purchase_tax_rate
      },
      order_by: good.name,
      order_by: [desc: pack.default],
      order_by: pack.id,
      distinct: good.name
    )
    |> Repo.one()
  end

  def good_names(terms, company, user) do
    from(good in subquery(good_query(company, user)),
      where: ilike(good.name, ^"%#{terms}%"),
      select: %{
        id: good.id,
        value: good.name
      },
      order_by: good.name
    )
    |> Repo.all()
  end

  def get_packaging_by_name(terms, good_id) do
    terms = terms |> to_string() |> String.trim()

    if terms == "" or blank_id?(good_id) do
      nil
    else
      from(pack in Packaging,
        where: pack.name == ^terms,
        where: pack.good_id == ^good_id,
        select: %{
          id: pack.id,
          value: pack.name,
          unit_multiplier: pack.unit_multiplier,
          default: pack.default
        }
      )
      |> Repo.one()
    end
  end

  def package_names(terms, good_id) do
    if blank_id?(good_id) do
      []
    else
      from(pack in Packaging,
        where: ilike(pack.name, ^"%#{terms}%"),
        where: pack.good_id == ^good_id,
        select: %{
          id: pack.id,
          value: pack.name,
          unit_multiplier: pack.unit_multiplier,
          default: pack.default
        }
      )
      |> Repo.all()
    end
  end

  defp blank_id?(id) when id in [nil, ""], do: true
  defp blank_id?(_), do: false

  defp good_query(company, user) do
    from(good in Good,
      join: com in subquery(Sys.user_company(company, user)),
      on: com.id == good.company_id,
      left_join: sac in Account,
      on: sac.id == good.sales_account_id,
      left_join: pac in Account,
      on: pac.id == good.purchase_account_id,
      left_join: stc in TaxCode,
      on: stc.id == good.sales_tax_code_id,
      left_join: ptc in TaxCode,
      on: ptc.id == good.purchase_tax_code_id,
      select: %Good{
        id: good.id,
        name: good.name,
        category: good.category,
        unit: good.unit,
        sales_account_name: sac.name,
        purchase_account_name: pac.name,
        sales_account_id: sac.id,
        purchase_account_id: pac.id,
        sales_tax_code_name: stc.code,
        purchase_tax_code_name: ptc.code,
        sales_tax_code_id: stc.id,
        purchase_tax_code_id: ptc.id,
        sales_tax_rate: stc.rate,
        purchase_tax_rate: ptc.rate,
        descriptions: good.descriptions,
        inserted_at: good.inserted_at,
        updated_at: good.updated_at
      }
    )
  end

  def good_index_query("", company, user, page: page, per_page: per_page) do
    from(good in subquery(good_query(company, user)),
      offset: ^((page - 1) * per_page),
      limit: ^per_page,
      preload: :packagings,
      order_by: [desc: good.updated_at]
    )
    |> Repo.all()
  end

  def good_index_query(terms, company, user, page: page, per_page: per_page) do
    from(good in subquery(good_query(company, user)),
      offset: ^((page - 1) * per_page),
      limit: ^per_page,
      preload: :packagings,
      order_by:
        ^similarity_order(
          ~w(name category unit purchase_account_name sales_account_name sales_tax_code_name purchase_tax_code_name)a,
          terms
        )
    )
    |> Repo.all()
  end
end
