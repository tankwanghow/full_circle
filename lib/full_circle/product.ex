defmodule FullCircle.Product do
  import Ecto.Query, warn: false
  import FullCircle.Helpers
  use Gettext, backend: FullCircleWeb.Gettext

  alias FullCircle.Accounting.{Account, TaxCode}

  alias FullCircle.Product.{
    Good,
    GoodPriceHistory,
    Packaging
  }

  alias FullCircle.{Repo, Sys}

  def categories() do
    ~w{Egg Chicken Pig Dung Feed FFB Vaccine Additive Others}
  end

  # PRICE HISTORY (archive + imported lines)

  @doc """
  Price history lines for a good, newest first.

  `side` is `"sale"`, `"purchase"`, or `nil` for both.
  """
  def list_price_history(good_id, company_id, opts \\ []) do
    side = Keyword.get(opts, :side)
    limit = Keyword.get(opts, :limit, 200)

    GoodPriceHistory
    |> where([h], h.good_id == ^good_id and h.company_id == ^company_id)
    |> then(fn q ->
      if side in ["sale", "purchase"], do: where(q, [h], h.side == ^side), else: q
    end)
    |> order_by([h], desc: h.doc_date, desc: h.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Monthly avg/min/max/last unit price for charts and summaries.
  """
  def price_history_monthly(good_id, company_id, side \\ nil) do
    q =
      from(h in GoodPriceHistory,
        where: h.good_id == ^good_id and h.company_id == ^company_id and h.unit_price > 0
      )

    q =
      if side in ["sale", "purchase"] do
        from(h in q, where: h.side == ^side)
      else
        q
      end

    from(h in q,
      group_by: [fragment("date_trunc('month', ?)", h.doc_date), h.side],
      order_by: [asc: fragment("date_trunc('month', ?)", h.doc_date), asc: h.side],
      select: %{
        month: fragment("date_trunc('month', ?)::date", h.doc_date),
        side: h.side,
        lines: count(h.id),
        avg_price: avg(h.unit_price),
        min_price: min(h.unit_price),
        max_price: max(h.unit_price),
        last_price:
          fragment("(array_agg(? ORDER BY ? DESC))[1]", h.unit_price, h.doc_date)
      }
    )
    |> Repo.all()
  end

  @doc "Most recent unit price for a good on a given side."
  def last_price(good_id, company_id, side) when side in ["sale", "purchase"] do
    GoodPriceHistory
    |> where(
      [h],
      h.good_id == ^good_id and h.company_id == ^company_id and h.side == ^side and
        h.unit_price > 0
    )
    |> order_by([h], desc: h.doc_date, desc: h.inserted_at)
    |> limit(1)
    |> select([h], h.unit_price)
    |> Repo.one()
  end

  def last_price(_, _, _), do: nil

  @doc """
  Default commercial egg grade good names used by the egg price chart.
  """
  def default_egg_grade_names do
    [
      "Egg Grade AA",
      "Egg Grade A",
      "Egg Grade B",
      "Egg Grade C",
      "Egg Grade D",
      "Egg Grade E",
      "Egg Grade F",
      "Egg Grade White",
      "Egg Grade Crack"
    ]
  end

  @doc """
  Monthly average unit prices for egg goods, combining imported archive
  (`good_price_histories`) with live invoice/pur-invoice lines after the
  archive ends so the series is continuous through today.

  Options:
    * `:side` - `"sale"` (default) or `"purchase"`
    * `:from` / `:to` - `Date` range (inclusive)
    * `:names` - list of good names; defaults to `default_egg_grade_names/0`
  """
  def egg_price_history_monthly(company_id, opts \\ []) do
    side = Keyword.get(opts, :side, "sale")
    names = Keyword.get(opts, :names) || default_egg_grade_names()
    to = Keyword.get(opts, :to) || Date.utc_today()
    from = Keyword.get(opts, :from) || Date.new!(to.year - 10, 1, 1)

    if side not in ["sale", "purchase"] or names == [] do
      []
    else
      archive_end =
        from(h in GoodPriceHistory,
          where: h.company_id == ^company_id and h.side == ^side,
          select: max(h.doc_date)
        )
        |> Repo.one()

      live_from =
        case archive_end do
          %Date{} = d -> Date.add(d, 1)
          _ -> from
        end

      archive_rows = egg_archive_monthly(company_id, side, from, to, names)

      live_rows =
        if Date.compare(live_from, to) != :gt do
          egg_live_monthly(company_id, side, max_date(live_from, from), to, names)
        else
          []
        end

      (archive_rows ++ live_rows)
      |> Enum.sort_by(fn r -> {r.month, r.good_name} end)
    end
  end

  defp max_date(a, b) do
    if Date.compare(a, b) == :lt, do: b, else: a
  end

  defp egg_archive_monthly(company_id, side, from, to, names) do
    from(h in GoodPriceHistory,
      join: g in Good,
      on: g.id == h.good_id,
      where:
        h.company_id == ^company_id and h.side == ^side and h.unit_price > 0 and
          h.doc_date >= ^from and h.doc_date <= ^to and g.name in ^names,
      group_by: [fragment("date_trunc('month', ?)::date", h.doc_date), g.name],
      order_by: [asc: fragment("date_trunc('month', ?)::date", h.doc_date), asc: g.name],
      select: %{
        month: fragment("date_trunc('month', ?)::date", h.doc_date),
        good_name: g.name,
        avg_price: avg(h.unit_price),
        min_price: min(h.unit_price),
        max_price: max(h.unit_price),
        lines: count(h.id),
        source: "archive"
      }
    )
    |> Repo.all()
  end

  defp egg_live_monthly(company_id, "sale", from, to, names) do
    from(d in FullCircle.Billing.InvoiceDetail,
      join: i in FullCircle.Billing.Invoice,
      on: i.id == d.invoice_id,
      join: g in Good,
      on: g.id == d.good_id,
      where:
        i.company_id == ^company_id and d.unit_price > 0 and d.quantity != 0 and
          i.invoice_date >= ^from and i.invoice_date <= ^to and g.name in ^names,
      group_by: [fragment("date_trunc('month', ?)::date", i.invoice_date), g.name],
      order_by: [asc: fragment("date_trunc('month', ?)::date", i.invoice_date), asc: g.name],
      select: %{
        month: fragment("date_trunc('month', ?)::date", i.invoice_date),
        good_name: g.name,
        avg_price: avg(d.unit_price),
        min_price: min(d.unit_price),
        max_price: max(d.unit_price),
        lines: count(d.id),
        source: "live"
      }
    )
    |> Repo.all()
  end

  defp egg_live_monthly(company_id, "purchase", from, to, names) do
    from(d in FullCircle.Billing.PurInvoiceDetail,
      join: i in FullCircle.Billing.PurInvoice,
      on: i.id == d.pur_invoice_id,
      join: g in Good,
      on: g.id == d.good_id,
      where:
        i.company_id == ^company_id and d.unit_price > 0 and d.quantity != 0 and
          i.pur_invoice_date >= ^from and i.pur_invoice_date <= ^to and g.name in ^names,
      group_by: [fragment("date_trunc('month', ?)::date", i.pur_invoice_date), g.name],
      order_by: [
        asc: fragment("date_trunc('month', ?)::date", i.pur_invoice_date),
        asc: g.name
      ],
      select: %{
        month: fragment("date_trunc('month', ?)::date", i.pur_invoice_date),
        good_name: g.name,
        avg_price: avg(d.unit_price),
        min_price: min(d.unit_price),
        max_price: max(d.unit_price),
        lines: count(d.id),
        source: "live"
      }
    )
    |> Repo.all()
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
        lock_version: good.lock_version,
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
