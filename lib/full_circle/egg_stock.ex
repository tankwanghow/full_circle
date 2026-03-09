defmodule FullCircle.EggStock do
  import Ecto.Query, warn: false
  import FullCircle.Authorization

  alias FullCircle.Repo
  alias FullCircle.EggStock.{EggGrade, EggStockDay, EggStockDayDetail}
  alias FullCircle.Accounting.Contact
  alias FullCircle.Billing.{Invoice, InvoiceDetail, PurInvoice, PurInvoiceDetail}
  alias FullCircle.ReceiveFund.{Receipt, ReceiptDetail}
  alias FullCircle.BillPay.{Payment, PaymentDetail}
  alias FullCircle.Product.{Good, Packaging}
  alias FullCircle.Layer.{Harvest, HarvestDetail}

  # --- Grades ---

  def list_grades(company_id) do
    from(g in EggGrade,
      where: g.company_id == ^company_id,
      order_by: [asc: g.position, asc: g.name]
    )
    |> Repo.all()
  end

  def grade_names(company_id) do
    list_grades(company_id) |> Enum.map(& &1.name)
  end

  def save_grades(company_id, grades_params) do
    grades_params
    |> Enum.with_index()
    |> Enum.reduce(Ecto.Multi.new(), fn {params, idx}, multi ->
      params = Map.put(params, "company_id", company_id)
      params = Map.put(params, "position", idx)

      if params["id"] && params["id"] != "" do
        grade = Repo.get!(EggGrade, params["id"])

        if params["delete"] == "true" do
          Ecto.Multi.delete(multi, {:delete_grade, idx}, grade)
        else
          cs = EggGrade.changeset(grade, params)
          Ecto.Multi.update(multi, {:update_grade, idx}, cs)
        end
      else
        if params["name"] && params["name"] != "" do
          cs = EggGrade.changeset(%EggGrade{}, params)
          Ecto.Multi.insert(multi, {:insert_grade, idx}, cs)
        else
          multi
        end
      end
    end)
    |> Repo.transaction()
  end

  # --- Harvest ---

  def harvest_total_for_date(company_id, date) do
    from(hd in HarvestDetail,
      join: h in Harvest,
      on: hd.harvest_id == h.id,
      where: h.company_id == ^company_id and h.har_date == ^date,
      select: coalesce(sum(hd.har_1 + hd.har_2 + hd.har_3), 0)
    )
    |> Repo.one() || 0
  end

  def compute_avg_harvest(company_id, lookback_days) do
    actual_dates =
      from(d in EggStockDay,
        where: d.company_id == ^company_id,
        where:
          fragment(
            "EXISTS (SELECT 1 FROM jsonb_each_text(?) AS kv WHERE kv.value != '' AND kv.value != '0')",
            d.closing_bal
          ),
        order_by: [desc: d.stock_date],
        limit: ^lookback_days,
        select: d.stock_date
      )
      |> Repo.all()

    if actual_dates == [] do
      0
    else
      totals = Enum.map(actual_dates, &harvest_total_for_date(company_id, &1))
      div(Enum.sum(totals), length(totals))
    end
  end

  # --- Stock Days ---

  def get_or_create_day(company_id, date) do
    case get_day(company_id, date) do
      nil -> create_day(company_id, date)
      day -> {:ok, day}
    end
  end

  def get_day(company_id, date) do
    from(d in EggStockDay,
      where: d.company_id == ^company_id and d.stock_date == ^date,
      preload: [egg_stock_day_details: ^__day_details_query__()]
    )
    |> Repo.one()
  end

  def __day_details_query__ do
    from(dd in EggStockDayDetail,
      left_join: c in Contact,
      on: c.id == dd.contact_id,
      order_by: [asc: dd.section, asc: dd.id],
      select: dd,
      select_merge: %{contact_name: c.name}
    )
  end

  defp create_day(company_id, date) do
    opening = get_previous_closing_bal(company_id, date)

    %EggStockDay{}
    |> EggStockDay.changeset(%{
      company_id: company_id,
      stock_date: date,
      opening_bal: opening,
      closing_bal: %{}
    })
    |> Repo.insert()
    |> case do
      {:ok, day} -> {:ok, Repo.preload(day, egg_stock_day_details: __day_details_query__())}
      error -> error
    end
  end

  def get_previous_ungraded_bal(company_id, date) do
    from(d in EggStockDay,
      where: d.company_id == ^company_id and d.stock_date < ^date,
      order_by: [desc: d.stock_date],
      limit: 1,
      select: d.ungraded_bal
    )
    |> Repo.one() || 0
  end

  def get_previous_closing_bal(company_id, date) do
    from(d in EggStockDay,
      where: d.company_id == ^company_id and d.stock_date < ^date,
      order_by: [desc: d.stock_date],
      limit: 1,
      select: d.closing_bal
    )
    |> Repo.one() || %{}
  end

  defp get_latest_actual_closing(company_id, before_date) do
    from(d in EggStockDay,
      where: d.company_id == ^company_id and d.stock_date < ^before_date,
      where:
        fragment(
          "EXISTS (SELECT 1 FROM jsonb_each_text(?) AS kv WHERE kv.value != '' AND kv.value != '0')",
          d.closing_bal
        ),
      order_by: [desc: d.stock_date],
      limit: 1,
      select: {d.stock_date, d.closing_bal}
    )
    |> Repo.one()
  end

  def save_day(day, attrs, company, user) do
    action = if day.id, do: :update_egg_stock_day, else: :create_egg_stock_day

    case can?(user, action, company) do
      true ->
        day
        |> EggStockDay.changeset(attrs)
        |> Repo.insert_or_update()

      false ->
        :not_authorise
    end
  end

  def delete_day(day, company, user) do
    case can?(user, :delete_egg_stock_day, company) do
      true -> Repo.delete(day)
      false -> :not_authorise
    end
  end

  # --- Actual Sales/Purchases ---

  def actual_sales_for_date(company_id, date) do
    grade_names = grade_names(company_id)
    trimmed_names = Enum.map(grade_names, &String.trim/1)
    name_map = Enum.zip(trimmed_names, grade_names) |> Map.new()

    invoice_rows =
      from(id in InvoiceDetail,
        join: inv in Invoice,
        on: id.invoice_id == inv.id,
        join: g in Good,
        on: id.good_id == g.id,
        join: c in Contact,
        on: inv.contact_id == c.id,
        left_join: pkg in Packaging,
        on: id.package_id == pkg.id,
        where: inv.company_id == ^company_id,
        where: g.name in ^trimmed_names,
        where: fragment("COALESCE(?, ?)", inv.load_date, inv.invoice_date) == ^date,
        select: %{
          contact_id: inv.contact_id,
          contact_name: c.name,
          good_name: g.name,
          doc_type: "Invoice",
          doc_id: inv.id,
          qty_trays:
            fragment("?::numeric / COALESCE(NULLIF(?, 0), 30)", id.quantity, pkg.unit_multiplier)
        }
      )
      |> Repo.all()

    receipt_rows =
      from(rd in ReceiptDetail,
        join: r in Receipt,
        on: rd.receipt_id == r.id,
        join: g in Good,
        on: rd.good_id == g.id,
        join: c in Contact,
        on: r.contact_id == c.id,
        left_join: pkg in Packaging,
        on: rd.package_id == pkg.id,
        where: r.company_id == ^company_id,
        where: g.name in ^trimmed_names,
        where: r.receipt_date == ^date,
        select: %{
          contact_id: r.contact_id,
          contact_name: c.name,
          good_name: g.name,
          doc_type: "Receipt",
          doc_id: r.id,
          qty_trays:
            fragment("?::numeric / COALESCE(NULLIF(?, 0), 30)", rd.quantity, pkg.unit_multiplier)
        }
      )
      |> Repo.all()

    aggregate_daily_results(invoice_rows ++ receipt_rows, name_map)
  end

  def actual_purchases_for_date(company_id, date) do
    grade_names = grade_names(company_id)
    trimmed_names = Enum.map(grade_names, &String.trim/1)
    name_map = Enum.zip(trimmed_names, grade_names) |> Map.new()

    pur_invoice_rows =
      from(pid in PurInvoiceDetail,
        join: pi in PurInvoice,
        on: pid.pur_invoice_id == pi.id,
        join: g in Good,
        on: pid.good_id == g.id,
        join: c in Contact,
        on: pi.contact_id == c.id,
        left_join: pkg in Packaging,
        on: pid.package_id == pkg.id,
        where: pi.company_id == ^company_id,
        where: g.name in ^trimmed_names,
        where: fragment("COALESCE(?, ?)", pi.load_date, pi.pur_invoice_date) == ^date,
        select: %{
          contact_id: pi.contact_id,
          contact_name: c.name,
          good_name: g.name,
          doc_type: "PurInvoice",
          doc_id: pi.id,
          qty_trays:
            fragment("?::numeric / COALESCE(NULLIF(?, 0), 30)", pid.quantity, pkg.unit_multiplier)
        }
      )
      |> Repo.all()

    payment_rows =
      from(pd in PaymentDetail,
        join: p in Payment,
        on: pd.payment_id == p.id,
        join: g in Good,
        on: pd.good_id == g.id,
        join: c in Contact,
        on: p.contact_id == c.id,
        left_join: pkg in Packaging,
        on: pd.package_id == pkg.id,
        where: p.company_id == ^company_id,
        where: g.name in ^trimmed_names,
        where: p.payment_date == ^date,
        select: %{
          contact_id: p.contact_id,
          contact_name: c.name,
          good_name: g.name,
          doc_type: "Payment",
          doc_id: p.id,
          qty_trays:
            fragment("?::numeric / COALESCE(NULLIF(?, 0), 30)", pd.quantity, pkg.unit_multiplier)
        }
      )
      |> Repo.all()

    aggregate_daily_results(pur_invoice_rows ++ payment_rows, name_map)
  end

  defp aggregate_daily_results(rows, name_map) do
    rows
    |> Enum.group_by(fn r -> {r.contact_id, r.contact_name} end)
    |> Enum.map(fn {{contact_id, contact_name}, contact_rows} ->
      quantities =
        contact_rows
        |> Enum.group_by(& &1.good_name)
        |> Map.new(fn {goods_name, grade_rows} ->
          total =
            Enum.reduce(grade_rows, Decimal.new(0), fn r, acc ->
              Decimal.add(acc, r.qty_trays || Decimal.new(0))
            end)

          grade_name = Map.get(name_map, goods_name, goods_name)
          {grade_name, total |> Decimal.round(0) |> Decimal.to_integer()}
        end)

      doc_links =
        contact_rows
        |> Enum.map(&{&1.doc_type, &1.doc_id})
        |> Enum.uniq()

      %{contact_id: contact_id, contact_name: contact_name, quantities: quantities, doc_links: doc_links}
    end)
  end

  # --- DOW Averages ---

  def sales_averages_by_dow(company_id, lookback_weeks) do
    grade_names = grade_names(company_id)
    trimmed_names = Enum.map(grade_names, &String.trim/1)
    name_map = Enum.zip(trimmed_names, grade_names) |> Map.new()
    compute_sales_averages(company_id, trimmed_names, name_map, lookback_weeks)
  end

  def purchase_averages_by_dow(company_id, lookback_weeks) do
    grade_names = grade_names(company_id)
    trimmed_names = Enum.map(grade_names, &String.trim/1)
    name_map = Enum.zip(trimmed_names, grade_names) |> Map.new()
    compute_purchase_averages(company_id, trimmed_names, name_map, lookback_weeks)
  end

  defp compute_sales_averages(company_id, grade_names, name_map, lookback_weeks) do
    cutoff = Date.add(Date.utc_today(), -(lookback_weeks * 7))

    invoice_query =
      from(id in InvoiceDetail,
        join: inv in Invoice,
        on: id.invoice_id == inv.id,
        join: g in Good,
        on: id.good_id == g.id,
        join: c in Contact,
        on: inv.contact_id == c.id,
        left_join: pkg in Packaging,
        on: id.package_id == pkg.id,
        where: inv.company_id == ^company_id,
        where: g.name in ^grade_names,
        where: fragment("COALESCE(?, ?)", inv.load_date, inv.invoice_date) >= ^cutoff,
        select: %{
          contact_id: inv.contact_id,
          contact_name: c.name,
          good_name: g.name,
          dow:
            fragment(
              "EXTRACT(ISODOW FROM COALESCE(?, ?))::integer",
              inv.load_date,
              inv.invoice_date
            ),
          qty_trays:
            fragment("?::numeric / COALESCE(NULLIF(?, 0), 30)", id.quantity, pkg.unit_multiplier)
        }
      )

    receipt_query =
      from(rd in ReceiptDetail,
        join: r in Receipt,
        on: rd.receipt_id == r.id,
        join: g in Good,
        on: rd.good_id == g.id,
        join: c in Contact,
        on: r.contact_id == c.id,
        left_join: pkg in Packaging,
        on: rd.package_id == pkg.id,
        where: r.company_id == ^company_id,
        where: g.name in ^grade_names,
        where: r.receipt_date >= ^cutoff,
        select: %{
          contact_id: r.contact_id,
          contact_name: c.name,
          good_name: g.name,
          dow: fragment("EXTRACT(ISODOW FROM ?)::integer", r.receipt_date),
          qty_trays:
            fragment("?::numeric / COALESCE(NULLIF(?, 0), 30)", rd.quantity, pkg.unit_multiplier)
        }
      )

    aggregate_dow_results(invoice_query, receipt_query, name_map, lookback_weeks)
  end

  defp compute_purchase_averages(company_id, grade_names, name_map, lookback_weeks) do
    cutoff = Date.add(Date.utc_today(), -(lookback_weeks * 7))

    pur_invoice_query =
      from(pid in PurInvoiceDetail,
        join: pi in PurInvoice,
        on: pid.pur_invoice_id == pi.id,
        join: g in Good,
        on: pid.good_id == g.id,
        join: c in Contact,
        on: pi.contact_id == c.id,
        left_join: pkg in Packaging,
        on: pid.package_id == pkg.id,
        where: pi.company_id == ^company_id,
        where: g.name in ^grade_names,
        where: fragment("COALESCE(?, ?)", pi.load_date, pi.pur_invoice_date) >= ^cutoff,
        select: %{
          contact_id: pi.contact_id,
          contact_name: c.name,
          good_name: g.name,
          dow:
            fragment(
              "EXTRACT(ISODOW FROM COALESCE(?, ?))::integer",
              pi.load_date,
              pi.pur_invoice_date
            ),
          qty_trays:
            fragment("?::numeric / COALESCE(NULLIF(?, 0), 30)", pid.quantity, pkg.unit_multiplier)
        }
      )

    payment_query =
      from(pd in PaymentDetail,
        join: p in Payment,
        on: pd.payment_id == p.id,
        join: g in Good,
        on: pd.good_id == g.id,
        join: c in Contact,
        on: p.contact_id == c.id,
        left_join: pkg in Packaging,
        on: pd.package_id == pkg.id,
        where: p.company_id == ^company_id,
        where: g.name in ^grade_names,
        where: p.payment_date >= ^cutoff,
        select: %{
          contact_id: p.contact_id,
          contact_name: c.name,
          good_name: g.name,
          dow: fragment("EXTRACT(ISODOW FROM ?)::integer", p.payment_date),
          qty_trays:
            fragment("?::numeric / COALESCE(NULLIF(?, 0), 30)", pd.quantity, pkg.unit_multiplier)
        }
      )

    aggregate_dow_results(pur_invoice_query, payment_query, name_map, lookback_weeks)
  end

  defp aggregate_dow_results(query1, query2, name_map, lookback_weeks) do
    rows1 = Repo.all(query1)
    rows2 = Repo.all(query2)
    all_rows = rows1 ++ rows2

    all_rows
    |> Enum.group_by(fn r -> {r.dow, r.contact_id, r.contact_name} end)
    |> Enum.map(fn {{dow, contact_id, contact_name}, rows} ->
      quantities =
        rows
        |> Enum.group_by(& &1.good_name)
        |> Map.new(fn {goods_name, grade_rows} ->
          total =
            Enum.reduce(grade_rows, Decimal.new(0), fn r, acc ->
              Decimal.add(acc, r.qty_trays || Decimal.new(0))
            end)

          avg =
            Decimal.div(total, Decimal.new(lookback_weeks))
            |> Decimal.round(0)
            |> Decimal.to_integer()

          grade_name = Map.get(name_map, goods_name, goods_name)
          {grade_name, avg}
        end)

      {dow, %{contact_id: contact_id, contact_name: contact_name, quantities: quantities}}
    end)
    |> Enum.group_by(fn {dow, _} -> dow end, fn {_, row} -> row end)
  end

  # --- Estimation ---

  def compute_estimated_opening(company_id, target_date, lookback_weeks, lookback_days) do
    grades = grade_names(company_id)

    case get_latest_actual_closing(company_id, target_date) do
      nil ->
        %{}

      {start_date, start_closing} ->
        if Date.diff(target_date, start_date) <= 1 do
          start_closing
        else
          avg_prod = compute_avg_production(company_id, lookback_days)
          sales_by_dow = sales_averages_by_dow(company_id, lookback_weeks)
          purchases_by_dow = purchase_averages_by_dow(company_id, lookback_weeks)

          Date.range(Date.add(start_date, 1), Date.add(target_date, -1))
          |> Enum.reduce(start_closing, fn date, prev_closing ->
            day = get_day(company_id, date)

            if day && has_actual_closing?(day.closing_bal) do
              day.closing_bal
            else
              dow = Date.day_of_week(date)

              {day_sales, day_purchases} =
                if day &&
                     Enum.any?(
                       day.egg_stock_day_details,
                       &(&1.section in ["actual_order", "actual_purchase"])
                     ) do
                  {sum_section(day.egg_stock_day_details, "actual_order", grades),
                   sum_section(day.egg_stock_day_details, "actual_purchase", grades)}
                else
                  {sum_dow_quantities(sales_by_dow[dow] || [], grades),
                   sum_dow_quantities(purchases_by_dow[dow] || [], grades)}
                end

              Map.new(grades, fn g ->
                o = to_int(prev_closing[g])
                p = to_int(avg_prod[g])
                s = to_int(day_sales[g])
                b = to_int(day_purchases[g])
                {g, o + p + b - s}
              end)
            end
          end)
        end
    end
  end

  def compute_avg_production(company_id, lookback_days) do
    grades = grade_names(company_id)

    actual_days =
      from(d in EggStockDay,
        where: d.company_id == ^company_id,
        where:
          fragment(
            "EXISTS (SELECT 1 FROM jsonb_each_text(?) AS kv WHERE kv.value != '' AND kv.value != '0')",
            d.closing_bal
          ),
        order_by: [desc: d.stock_date],
        limit: ^lookback_days,
        preload: [egg_stock_day_details: ^__day_details_query__()]
      )
      |> Repo.all()

    if actual_days == [] do
      Map.new(grades, &{&1, 0})
    else
      prods = Enum.map(actual_days, &compute_day_production(grades, &1))
      count = length(prods)

      Enum.reduce(prods, Map.new(grades, &{&1, 0}), fn prod, acc ->
        Map.merge(acc, prod, fn _k, v1, v2 -> v1 + v2 end)
      end)
      |> Map.new(fn {k, v} -> {k, div(v, count)} end)
    end
  end

  defp compute_day_production(grades, day) do
    opening = get_previous_closing_bal(day.company_id, day.stock_date)
    closing = day.closing_bal || %{}
    expired = day.expired || %{}

    actual_sales = actual_sales_for_date(day.company_id, day.stock_date)
    actual_purchases = actual_purchases_for_date(day.company_id, day.stock_date)

    sold =
      Enum.reduce(actual_sales, Map.new(grades, &{&1, 0}), fn row, acc ->
        Map.merge(acc, row.quantities || %{}, fn _k, v1, v2 -> to_int(v1) + to_int(v2) end)
      end)

    bought =
      Enum.reduce(actual_purchases, Map.new(grades, &{&1, 0}), fn row, acc ->
        Map.merge(acc, row.quantities || %{}, fn _k, v1, v2 -> to_int(v1) + to_int(v2) end)
      end)

    Map.new(grades, fn g ->
      o = to_int(opening[g])
      c = to_int(closing[g])
      e = to_int(expired[g])
      b = to_int(bought[g])
      s = to_int(sold[g])
      {g, s + e + c - o - b}
    end)
  end

  # --- Helpers ---

  defp has_actual_closing?(nil), do: false
  defp has_actual_closing?(bal) when bal == %{}, do: false

  defp has_actual_closing?(bal) when is_map(bal) do
    Enum.any?(bal, fn {_k, v} -> v != "" and v != "0" and v != nil end)
  end

  defp sum_section(details, section, grades) do
    details
    |> Enum.filter(&(&1.section == section))
    |> Enum.reduce(Map.new(grades, fn g -> {g, 0} end), fn detail, acc ->
      Map.merge(acc, detail.quantities || %{}, fn _k, v1, v2 ->
        to_int(v1) + to_int(v2)
      end)
    end)
  end

  defp sum_dow_quantities(rows, grades) do
    rows
    |> Enum.reduce(Map.new(grades, fn g -> {g, 0} end), fn row, acc ->
      Map.merge(acc, row.quantities || %{}, fn _k, v1, v2 ->
        to_int(v1) + to_int(v2)
      end)
    end)
  end

  defp to_int(nil), do: 0
  defp to_int(v) when is_integer(v), do: v

  defp to_int(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp to_int(v) when is_float(v), do: round(v)
end
