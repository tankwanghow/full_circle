defmodule FullCircle.EggStock do
  import Ecto.Query, warn: false
  import FullCircle.Authorization

  alias FullCircle.Repo
  alias FullCircle.EggStock.{EggGrade, EggStockDay, EggStockDayDetail, DowTemplateLine}
  alias FullCircle.Accounting.Contact
  alias FullCircle.Billing.{Invoice, InvoiceDetail, PurInvoice, PurInvoiceDetail}
  alias FullCircle.ReceiveFund.{Receipt, ReceiptDetail}
  alias FullCircle.BillPay.{Payment, PaymentDetail}
  alias FullCircle.Product.{Good, Packaging}
  alias FullCircle.Layer.{Harvest, HarvestDetail}

  @planned_sales "planned_order"
  @planned_purchase "planned_purchase"
  @legacy_planned_sales "actual_order"
  @legacy_planned_purchase "actual_purchase"

  def planned_sales_section, do: @planned_sales
  def planned_purchase_section, do: @planned_purchase

  def planned_sales_sections, do: [@planned_sales, @legacy_planned_sales]
  def planned_purchase_sections, do: [@planned_purchase, @legacy_planned_purchase]

  def planned_sections,
    do: planned_sales_sections() ++ planned_purchase_sections()

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
      order_by: [
        asc: dd.section,
        asc: dd.position,
        asc: dd.id
      ],
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

  # --- Weekly DOW books (ODS-style 1–7) ---

  def list_dow_lines(company_id, kind, dow) when kind in [:sales, :purchase, "sales", "purchase"] do
    kind = to_string(kind)

    from(l in DowTemplateLine,
      left_join: c in Contact,
      on: c.id == l.contact_id,
      where: l.company_id == ^company_id and l.kind == ^kind and l.dow == ^dow,
      order_by: [asc: l.position, asc: l.id],
      select: l,
      select_merge: %{contact_name: c.name}
    )
    |> Repo.all()
  end

  def dow_totals(company_id, kind, dow, grades \\ nil) do
    grades = grades || grade_names(company_id)

    list_dow_lines(company_id, kind, dow)
    |> Enum.reject(& &1.is_separator)
    |> sum_line_quantities(grades)
  end

  def save_dow_lines(company_id, kind, dow, lines_params, company, user)
      when kind in [:sales, :purchase, "sales", "purchase"] do
    kind = to_string(kind)

    case can?(user, :update_egg_stock_day, company) do
      false ->
        :not_authorise

      true ->
        existing =
          from(l in DowTemplateLine,
            where: l.company_id == ^company_id and l.kind == ^kind and l.dow == ^dow
          )
          |> Repo.all()
          |> Map.new(&{&1.id, &1})

        multi =
          lines_params
          |> normalize_indexed_params()
          |> Enum.with_index()
          |> Enum.reduce({Ecto.Multi.new(), 0}, fn {params, idx}, {multi, next_pos} ->
            delete? = params["delete"] in [true, "true"]
            is_separator = params["is_separator"] in [true, "true"]

            {params, next_pos} =
              if delete? do
                {params, next_pos}
              else
                {Map.put(params, "position", next_pos), next_pos + 1}
              end

            params =
              params
              |> Map.put("company_id", company_id)
              |> Map.put("kind", kind)
              |> Map.put("dow", dow)
              |> Map.put_new("group_name", "")
              |> Map.put_new("group_position", 0)
              |> Map.put("is_separator", is_separator)
              |> normalize_group_fields()
              |> normalize_quantities()

            id = blank_to_nil(params["id"])

            multi =
              cond do
                id && Map.has_key?(existing, id) && delete? ->
                  Ecto.Multi.delete(multi, {:delete_dow, idx}, Map.fetch!(existing, id))

                id && Map.has_key?(existing, id) ->
                  line = Map.fetch!(existing, id)
                  cs = DowTemplateLine.changeset(line, params)
                  Ecto.Multi.update(multi, {:update_dow, idx}, cs)

                !delete? && has_line_content?(params) ->
                  cs = DowTemplateLine.changeset(%DowTemplateLine{}, params)
                  Ecto.Multi.insert(multi, {:insert_dow, idx}, cs)

                true ->
                  multi
              end

            {multi, next_pos}
          end)
          |> elem(0)

        # Delete existing lines not present in params (full replace semantics for listed ids only;
        # lines omitted without delete flag stay unless client sends full list — we expect full list)
        submitted_ids =
          lines_params
          |> normalize_indexed_params()
          |> Enum.map(&blank_to_nil(&1["id"]))
          |> Enum.reject(&is_nil/1)
          |> MapSet.new()

        multi =
          Enum.reduce(existing, multi, fn {id, line}, multi ->
            if MapSet.member?(submitted_ids, id) do
              multi
            else
              Ecto.Multi.delete(multi, {:purge_dow, id}, line)
            end
          end)

        case Repo.transaction(multi) do
          {:ok, _} -> {:ok, list_dow_lines(company_id, kind, dow)}
          {:error, _op, cs, _} -> {:error, cs}
        end
    end
  end

  defp has_line_content?(params) do
    if params["is_separator"] in [true, "true"] do
      true
    else
      name = String.trim(params["contact_name"] || "")
      contact_id = blank_to_nil(params["contact_id"])
      quantities = params["quantities"] || %{}

      (name != "" or not is_nil(contact_id)) or
        Enum.any?(quantities, fn {_k, v} -> to_int(v) != 0 end)
    end
  end

  defp normalize_group_fields(params) do
    group_name = params["group_name"] |> to_string() |> String.trim()
    group_position = to_int(params["group_position"] || 0)

    params
    |> Map.put("group_name", group_name)
    |> Map.put("group_position", group_position)
  end

  defp normalize_quantities(params) do
    quantities =
      (params["quantities"] || %{})
      |> Enum.map(fn {k, v} -> {k, to_int(v)} end)
      |> Map.new()

    Map.put(params, "quantities", quantities)
  end

  defp normalize_indexed_params(params) when is_list(params), do: params

  defp normalize_indexed_params(params) when is_map(params) do
    params
    |> Enum.sort_by(fn {k, _} ->
      case Integer.parse(to_string(k)) do
        {n, _} -> n
        :error -> 0
      end
    end)
    |> Enum.map(fn {_k, v} -> v end)
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(v), do: v

  # --- Planned SO/PO for a date (day override wins over DOW book) ---

  def day_has_planned_section?(day, section) when is_binary(section) do
    sections =
      case section do
        s when s in [@planned_sales, @legacy_planned_sales] -> planned_sales_sections()
        s when s in [@planned_purchase, @legacy_planned_purchase] -> planned_purchase_sections()
        _ -> [section]
      end

    day &&
      Enum.any?(day.egg_stock_day_details || [], fn d ->
        d.section in sections
      end)
  end

  def day_has_planned_sales?(day), do: day_has_planned_section?(day, @planned_sales)
  def day_has_planned_purchases?(day), do: day_has_planned_section?(day, @planned_purchase)

  def planned_sales_for_date(company_id, date) do
    planned_lines_for_date(company_id, date, :sales, planned_sales_sections())
  end

  def planned_purchases_for_date(company_id, date) do
    planned_lines_for_date(company_id, date, :purchase, planned_purchase_sections())
  end

  defp planned_lines_for_date(company_id, date, kind, sections) do
    day = get_day(company_id, date)

    rows =
      if day && Enum.any?(day.egg_stock_day_details || [], &(&1.section in sections)) do
        day.egg_stock_day_details
        |> Enum.filter(&(&1.section in sections))
        |> Enum.reject(& &1.is_separator)
        |> Enum.map(&detail_to_planned_row/1)
      else
        list_dow_lines(company_id, kind, Date.day_of_week(date))
        |> Enum.reject(& &1.is_separator)
        |> Enum.map(&dow_to_planned_row/1)
      end

    # Linked documents are source of truth for quantities
    actuals =
      case kind do
        :sales -> actual_sales_for_date(company_id, date)
        :purchase -> actual_purchases_for_date(company_id, date)
        "sales" -> actual_sales_for_date(company_id, date)
        "purchase" -> actual_purchases_for_date(company_id, date)
      end

    overlay_actual_quantities(rows, actuals)
  end

  def planned_sales_totals(company_id, date, grades \\ nil) do
    grades = grades || grade_names(company_id)
    planned_sales_for_date(company_id, date) |> sum_planned_rows(grades)
  end

  def planned_purchases_totals(company_id, date, grades \\ nil) do
    grades = grades || grade_names(company_id)
    planned_purchases_for_date(company_id, date) |> sum_planned_rows(grades)
  end

  @doc """
  For planned lines that have matching actual document rows (same contact),
  replace quantities with the document totals so planned reflects issued docs.
  """
  def overlay_actual_quantities(planned_rows, actual_rows) do
    by_contact =
      (actual_rows || [])
      |> Enum.filter(fn r -> r.contact_id not in [nil, ""] end)
      |> Map.new(fn r -> {to_string(r.contact_id), r.quantities || %{}} end)

    Enum.map(planned_rows || [], fn row ->
      cid = row[:contact_id] || row["contact_id"]

      if cid not in [nil, ""] and Map.has_key?(by_contact, to_string(cid)) do
        Map.put(row, :quantities, normalize_qty_map(by_contact[to_string(cid)]))
      else
        row
      end
    end)
  end

  @doc """
  Ensure every contact with actual document activity has a planned line.
  Orphan docs (no matching planned contact) get a new locked planned row.
  In-memory only; returns `{day, added?}`.
  """
  def ensure_planned_lines_for_actuals(day, actual_sales, actual_purchases) do
    details = day.egg_stock_day_details || []

    {details, added_sales?} =
      ensure_section_lines_for_actuals(
        details,
        actual_sales,
        planned_sales_section(),
        planned_sales_sections()
      )

    {details, added_purchases?} =
      ensure_section_lines_for_actuals(
        details,
        actual_purchases,
        planned_purchase_section(),
        planned_purchase_sections()
      )

    {%{day | egg_stock_day_details: details}, added_sales? or added_purchases?}
  end

  defp ensure_section_lines_for_actuals(details, actual_rows, section, sections) do
    existing_ids =
      details
      |> Enum.filter(&(&1.section in sections and !&1.is_separator))
      |> Enum.map(& &1.contact_id)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new(&to_string/1)

    orphans =
      (actual_rows || [])
      |> Enum.filter(fn r ->
        r.contact_id not in [nil, ""] and
          not MapSet.member?(existing_ids, to_string(r.contact_id))
      end)
      # one row per contact (actuals already aggregated by contact)
      |> Enum.uniq_by(&to_string(&1.contact_id))

    if orphans == [] do
      {details, false}
    else
      base_pos =
        details
        |> Enum.filter(&(&1.section in sections))
        |> Enum.map(&(&1.position || 0))
        |> Enum.max(fn -> -1 end)

      new_lines =
        orphans
        |> Enum.with_index()
        |> Enum.map(fn {row, i} ->
          %EggStockDayDetail{
            section: section,
            contact_id: row.contact_id,
            contact_name: row.contact_name,
            quantities: normalize_qty_map(row.quantities || %{}),
            group_name: "",
            group_position: 0,
            is_separator: false,
            position: base_pos + 1 + i,
            ignore: false,
            _persistent_id: length(details) + i
          }
        end)

      {details ++ new_lines, true}
    end
  end

  @doc """
  Sync day detail structs' quantities from actual sales/purchases (in-memory).
  Returns `{day, changed?}` where changed? is true if any line quantities differed.
  """
  def sync_day_details_from_actuals(day, actual_sales, actual_purchases) do
    sales_by =
      (actual_sales || [])
      |> Enum.filter(fn r -> r.contact_id not in [nil, ""] end)
      |> Map.new(fn r -> {to_string(r.contact_id), normalize_qty_map(r.quantities || %{})} end)

    purchases_by =
      (actual_purchases || [])
      |> Enum.filter(fn r -> r.contact_id not in [nil, ""] end)
      |> Map.new(fn r -> {to_string(r.contact_id), normalize_qty_map(r.quantities || %{})} end)

    {details, changed?} =
      Enum.map_reduce(day.egg_stock_day_details || [], false, fn d, ch ->
        cid = d.contact_id && to_string(d.contact_id)

        actual_qty =
          cond do
            cid && d.section in planned_sales_sections() -> Map.get(sales_by, cid)
            cid && d.section in planned_purchase_sections() -> Map.get(purchases_by, cid)
            true -> nil
          end

        if actual_qty do
          current = normalize_qty_map(d.quantities || %{})

          if current == actual_qty do
            {d, ch}
          else
            # Keep full grade map for form display (zeros for missing grades)
            {%{d | quantities: actual_qty}, true}
          end
        else
          {d, ch}
        end
      end)

    {%{day | egg_stock_day_details: details}, changed?}
  end

  @doc """
  Persist planned-detail quantities that were synced from documents.

  Uses direct updates (not cast_assoc) so map quantity changes are always written.
  Returns the day reloaded with details.
  """
  def persist_synced_detail_quantities(day, company, user) do
    case can?(user, :update_egg_stock_day, company) do
      false ->
        {:error, :not_authorise}

      true ->
        day.egg_stock_day_details
        |> Enum.filter(& &1.id)
        |> Enum.each(fn d ->
          from(dd in EggStockDayDetail, where: dd.id == ^d.id)
          |> Repo.update_all(set: [quantities: normalize_qty_map(d.quantities || %{})])
        end)

        from(d in EggStockDay, where: d.id == ^day.id)
        |> Repo.update_all(set: [updated_at: DateTime.utc_now() |> DateTime.truncate(:second)])

        reloaded =
          get_day(day.company_id, day.stock_date) ||
            Repo.preload(day, [egg_stock_day_details: __day_details_query__()], force: true)

        {:ok, reloaded}
    end
  end

  # Drop Phoenix _unused_ keys and zero values for stable compare/store
  def normalize_qty_map(map) when is_map(map) do
    map
    |> Enum.reject(fn {k, _v} ->
      ks = to_string(k)
      String.starts_with?(ks, "_unused")
    end)
    |> Map.new(fn {k, v} -> {to_string(k), to_int(v)} end)
    |> Enum.reject(fn {_k, v} -> v == 0 end)
    |> Map.new()
  end

  def normalize_qty_map(_), do: %{}

  defp detail_to_planned_row(d) do
    %{
      id: d.id,
      contact_id: d.contact_id,
      contact_name: d.contact_name,
      quantities: d.quantities || %{},
      ignore: d.ignore || false,
      is_separator: d.is_separator || false,
      position: d.position || 0,
      group_name: d.group_name || "",
      group_position: d.group_position || 0,
      source: :day
    }
  end

  defp dow_to_planned_row(l) do
    %{
      id: l.id,
      contact_id: l.contact_id,
      contact_name: l.contact_name,
      quantities: l.quantities || %{},
      ignore: false,
      is_separator: l.is_separator || false,
      position: l.position || 0,
      group_name: l.group_name || "",
      group_position: l.group_position || 0,
      source: :book
    }
  end

  defp sum_planned_rows(rows, grades) do
    rows
    |> Enum.reject(&(&1[:ignore] || &1[:is_separator]))
    |> sum_line_quantities(grades)
  end

  defp sum_line_quantities(lines, grades) do
    lines
    |> Enum.reject(fn line ->
      Map.get(line, :is_separator) || Map.get(line, "is_separator") in [true, "true"]
    end)
    |> Enum.reduce(Map.new(grades, &{&1, 0}), fn line, acc ->
      quantities = Map.get(line, :quantities) || Map.get(line, "quantities") || %{}
      Map.merge(acc, quantities, fn _k, v1, v2 -> to_int(v1) + to_int(v2) end)
    end)
  end

  def copy_dow_book_to_day(day, kind, company, user)
      when kind in [:sales, :purchase, "sales", "purchase"] do
    kind = to_string(kind)
    section = if kind == "sales", do: @planned_sales, else: @planned_purchase
    sections = if kind == "sales", do: planned_sales_sections(), else: planned_purchase_sections()

    case can?(user, :update_egg_stock_day, company) do
      false ->
        :not_authorise

      true ->
        book_lines = list_dow_lines(day.company_id, kind, Date.day_of_week(day.stock_date))

        keep =
          (day.egg_stock_day_details || [])
          |> Enum.reject(&(&1.section in sections))
          |> Enum.map(&detail_to_attr/1)

        new_lines =
          book_lines
          |> Enum.with_index()
          |> Enum.map(fn {line, idx} ->
            %{
              "section" => section,
              "contact_id" => line.contact_id,
              "contact_name" => line.contact_name,
              "quantities" => line.quantities || %{},
              "group_name" => line.group_name || "",
              "group_position" => line.group_position || 0,
              "is_separator" => line.is_separator || false,
              "position" => line.position || idx,
              "ignore" => "false",
              "_persistent_id" => idx
            }
          end)

        attrs = %{
          "egg_stock_day_details" =>
            (keep ++ new_lines)
            |> Enum.with_index()
            |> Map.new(fn {v, i} -> {to_string(i), stringify_keys(v)} end)
        }

        day
        |> Map.put(:egg_stock_day_details, Enum.filter(day.egg_stock_day_details || [], & &1.id))
        |> save_day(attrs, company, user)
        |> case do
          {:ok, updated} ->
            {:ok, Repo.preload(updated, [egg_stock_day_details: __day_details_query__()], force: true)}

          other ->
            other
        end
    end
  end

  def clear_day_planned_section(day, kind, company, user)
      when kind in [:sales, :purchase, "sales", "purchase"] do
    kind = to_string(kind)
    sections = if kind == "sales", do: planned_sales_sections(), else: planned_purchase_sections()

    case can?(user, :update_egg_stock_day, company) do
      false ->
        :not_authorise

      true ->
        keep =
          (day.egg_stock_day_details || [])
          |> Enum.reject(&(&1.section in sections))
          |> Enum.map(&detail_to_attr/1)

        attrs = %{
          "egg_stock_day_details" =>
            keep
            |> Enum.with_index()
            |> Map.new(fn {v, i} -> {to_string(i), stringify_keys(v)} end)
        }

        day
        |> Map.put(:egg_stock_day_details, Enum.filter(day.egg_stock_day_details || [], & &1.id))
        |> save_day(attrs, company, user)
        |> case do
          {:ok, updated} ->
            {:ok, Repo.preload(updated, [egg_stock_day_details: __day_details_query__()], force: true)}

          other ->
            other
        end
    end
  end

  defp detail_to_attr(d) do
    %{
      "id" => d.id,
      "section" => normalize_section(d.section),
      "contact_id" => d.contact_id,
      "contact_name" => d.contact_name,
      "quantities" => d.quantities || %{},
      "group_name" => d.group_name || "",
      "group_position" => d.group_position || 0,
      "is_separator" => d.is_separator || false,
      "position" => d.position || 0,
      "ignore" => to_string(d.ignore || false)
    }
  end

  defp normalize_section(@legacy_planned_sales), do: @planned_sales
  defp normalize_section(@legacy_planned_purchase), do: @planned_purchase
  defp normalize_section(s), do: s

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  # --- Actual Sales/Purchases (history from documents) ---

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
        where: fragment("COALESCE(?, ?)", r.load_date, r.receipt_date) == ^date,
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

      %{
        contact_id: contact_id,
        contact_name: contact_name,
        quantities: quantities,
        doc_links: doc_links
      }
    end)
    |> Enum.sort_by(& &1.contact_name)
  end

  # --- Estimation / forecast (hybrid) ---

  def compute_estimated_opening(company_id, target_date, lookback_days) do
    grades = grade_names(company_id)

    case get_latest_actual_closing(company_id, target_date) do
      nil ->
        %{}

      {start_date, start_closing} ->
        if Date.diff(target_date, start_date) <= 1 do
          start_closing
        else
          avg_prod = compute_avg_production(company_id, lookback_days)

          Date.range(Date.add(start_date, 1), Date.add(target_date, -1))
          |> Enum.reduce(start_closing, fn date, prev_closing ->
            day = get_day(company_id, date)

            if day && has_actual_closing?(day.closing_bal) do
              day.closing_bal
            else
              day_sales = planned_sales_totals(company_id, date, grades)
              day_purchases = planned_purchases_totals(company_id, date, grades)

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

  def production_report(company_id, from_date, to_date) do
    grades = grade_names(company_id)

    days =
      from(d in EggStockDay,
        where: d.company_id == ^company_id,
        where: d.stock_date >= ^from_date and d.stock_date <= ^to_date,
        where:
          fragment(
            "EXISTS (SELECT 1 FROM jsonb_each_text(?) AS kv WHERE kv.value != '' AND kv.value != '0')",
            d.closing_bal
          ),
        order_by: [asc: d.stock_date]
      )
      |> Repo.all()

    Enum.map(days, fn day ->
      prod = compute_day_production(grades, day)
      total = harvest_total_for_date(company_id, day.stock_date)
      %{date: day.stock_date, quantities: prod, total: total}
    end)
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

  def compute_7day_forecast(company_id, start_date, lookback_days) do
    grades = grade_names(company_id)
    avg_prod = compute_avg_production(company_id, lookback_days)

    opening = compute_estimated_opening(company_id, start_date, lookback_days)

    0..6
    |> Enum.map_reduce(opening, fn offset, prev_closing ->
      date = Date.add(start_date, offset)
      day = get_day(company_id, date)

      day_sales = planned_sales_totals(company_id, date, grades)
      day_purchases = planned_purchases_totals(company_id, date, grades)

      closing =
        if day && has_actual_closing?(day.closing_bal) do
          day.closing_bal
        else
          Map.new(grades, fn g ->
            o = to_int(prev_closing[g])
            p = to_int(avg_prod[g])
            s = to_int(day_sales[g])
            b = to_int(day_purchases[g])
            {g, o + p + b - s}
          end)
        end

      {%{
         date: date,
         closing: closing,
         sales: day_sales,
         purchases: day_purchases,
         production: avg_prod
       }, closing}
    end)
    |> elem(0)
  end

  # --- Helpers ---

  defp has_actual_closing?(nil), do: false
  defp has_actual_closing?(bal) when bal == %{}, do: false

  defp has_actual_closing?(bal) when is_map(bal) do
    Enum.any?(bal, fn {_k, v} -> v != "" and v != "0" and v != nil and to_int(v) != 0 end)
  end

  def to_int(nil), do: 0
  def to_int(v) when is_integer(v), do: v

  def to_int(v) when is_binary(v) do
    case Integer.parse(String.trim(v)) do
      {n, _} -> n
      :error -> 0
    end
  end

  def to_int(v) when is_float(v), do: round(v)
  def to_int(%Decimal{} = v), do: v |> Decimal.round(0) |> Decimal.to_integer()
  def to_int(_), do: 0
end
