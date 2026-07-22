defmodule FullCircleWeb.EggStockLive.Form do
  use FullCircleWeb, :live_view

  alias FullCircle.EggStock
  alias FullCircle.EggStock.{EggStockDay, EggStockDayDetail}
  alias FullCircle.Accounting
  alias FullCircle.Sys

  @impl true
  def mount(_params, _session, socket) do
    settings =
      Sys.load_settings("EggStock", socket.assigns.current_company, socket.assigns.current_user)

    days = Sys.get_setting(settings, "EggStock", "lookback-days") |> String.to_integer()

    autosave_delay =
      case Enum.find(settings, fn x -> x.page == "EggStock" and x.code == "autosave-delay" end) do
        nil -> 2
        s -> Map.get(s.values, s.value) |> String.to_integer()
      end

    {:ok,
     socket
     |> assign(active_tab: "now")
     |> assign(settings: settings)
     |> assign(lookback_days: days)
     |> assign(autosave_delay: autosave_delay)
     |> assign(save_status: nil)
     |> assign(dow_kind: "sales")
     |> assign(dow: Date.day_of_week(Date.utc_today()))
     |> assign(page_title: gettext("Egg Stock"))}
  end

  @impl true
  def handle_params(params, _url, socket) do
    company = socket.assigns.current_company
    date = parse_date(params["date"])

    grades = EggStock.list_grades(company.id)
    grade_names = Enum.map(grades, & &1.name)
    grade_labels = Map.new(grades, fn g -> {g.name, g.nickname || g.name} end)
    today = Date.utc_today()
    editable = Date.compare(date, today) != :lt
    is_future = Date.compare(date, today) == :gt

    {:noreply,
     socket
     |> assign(
       date: date,
       grades: grades,
       grade_names: grade_names,
       grade_labels: grade_labels,
       editable: editable,
       is_future: is_future
     )
     |> load_tab_data(socket.assigns.active_tab)}
  end

  defp parse_date(nil), do: Date.utc_today()

  defp parse_date(date_str) do
    case Date.from_iso8601(date_str) do
      {:ok, date} -> date
      _ -> Date.utc_today()
    end
  end

  defp load_tab_data(socket, "now") do
    company = socket.assigns.current_company
    date = socket.assigns.date
    is_future = socket.assigns.is_future
    lookback_days = socket.assigns.lookback_days

    case EggStock.get_or_create_day(company.id, date) do
      {:ok, day} ->
        if is_future do
          load_future_day(socket, day, company, date, lookback_days)
        else
          load_today_or_past_day(socket, day, company, date, lookback_days)
        end

      {:error, _cs} ->
        socket |> put_flash(:error, gettext("Failed to load day data"))
    end
  end

  defp load_tab_data(socket, "estimated") do
    company = socket.assigns.current_company
    date = socket.assigns.date
    lookback_days = socket.assigns.lookback_days

    forecast = EggStock.compute_7day_forecast(company.id, date, lookback_days)
    assign(socket, forecast: forecast)
  end

  defp load_tab_data(socket, "weekly_sales") do
    load_weekly_tab(socket, "sales")
  end

  defp load_tab_data(socket, "weekly_purchases") do
    load_weekly_tab(socket, "purchase")
  end

  defp load_tab_data(socket, "settings") do
    company = socket.assigns.current_company
    grades = EggStock.list_grades(company.id)
    assign(socket, grades: grades, grades_params: grades_to_params(grades))
  end

  defp load_tab_data(socket, _), do: socket

  defp load_weekly_tab(socket, kind) do
    company = socket.assigns.current_company
    dow = socket.assigns.dow
    lines = EggStock.list_dow_lines(company.id, kind, dow)

    socket
    |> assign(dow_kind: kind)
    |> assign(dow_lines: lines)
    |> assign(dow_params: dow_lines_to_params(lines))
  end

  defp load_future_day(socket, day, company, date, lookback_days) do
    est_opening = EggStock.compute_estimated_opening(company.id, date, lookback_days)
    est_production = EggStock.compute_avg_production(company.id, lookback_days)
    est_harvest = EggStock.compute_avg_harvest(company.id, lookback_days)

    day = %{day | opening_bal: est_opening}
    day = seed_planned_details_from_book(day, company.id, date)

    planned_sales = planned_rows_from_day(day, :sales)
    planned_purchases = planned_rows_from_day(day, :purchase)

    est_closing =
      compute_est_closing(
        est_opening,
        est_production,
        planned_sales,
        planned_purchases,
        socket.assigns.grade_names
      )

    socket
    |> assign(
      day: day,
      est_opening: est_opening,
      est_production: est_production,
      est_harvest: est_harvest,
      est_closing: est_closing,
      actual_sales: [],
      actual_purchases: [],
      harvested: 0,
      yesterday_ug: 0
    )
    |> assign_day_form(day)
  end

  defp load_today_or_past_day(socket, day, company, date, lookback_days) do
    opening = EggStock.get_previous_closing_bal(company.id, date)
    day = %{day | opening_bal: opening}

    actual_sales = EggStock.actual_sales_for_date(company.id, date)
    actual_purchases = EggStock.actual_purchases_for_date(company.id, date)
    harvested = EggStock.harvest_total_for_date(company.id, date)

    est_harvest =
      if harvested == 0, do: EggStock.compute_avg_harvest(company.id, lookback_days), else: nil

    yesterday_ug = EggStock.get_previous_ungraded_bal(company.id, date)

    day =
      if socket.assigns.editable do
        seed_planned_details_from_book(day, company.id, date)
      else
        day
      end

    # Documents without a planned line → add lines (same board, no special marker)
    {day, _orphans_added?} =
      if socket.assigns.editable do
        EggStock.ensure_planned_lines_for_actuals(day, actual_sales, actual_purchases)
      else
        {day, false}
      end

    # Linked documents are source of truth for planned line quantities
    {day, qty_changed?} =
      EggStock.sync_day_details_from_actuals(day, actual_sales, actual_purchases)

    day =
      if qty_changed? do
        case EggStock.persist_synced_detail_quantities(
               day,
               company,
               socket.assigns.current_user
             ) do
          {:ok, reloaded} ->
            {with_docs, _} =
              EggStock.ensure_planned_lines_for_actuals(
                reloaded,
                actual_sales,
                actual_purchases
              )

            {synced, _} =
              EggStock.sync_day_details_from_actuals(
                with_docs,
                actual_sales,
                actual_purchases
              )

            synced

          _ ->
            day
        end
      else
        day
      end

    planned_sales = planned_rows_from_day(day, :sales)
    planned_purchases = planned_rows_from_day(day, :purchase)

    {est_production, est_closing} =
      if socket.assigns.editable do
        prod = EggStock.compute_avg_production(company.id, lookback_days)

        closing =
          compute_est_closing(
            opening,
            prod,
            planned_sales,
            planned_purchases,
            socket.assigns.grade_names
          )

        {prod, closing}
      else
        {nil, nil}
      end

    socket
    |> assign(
      day: day,
      actual_sales: actual_sales,
      actual_purchases: actual_purchases,
      harvested: harvested,
      yesterday_ug: yesterday_ug,
      est_opening: nil,
      est_production: est_production,
      est_harvest: est_harvest,
      est_closing: est_closing
    )
    |> assign_day_form(day)
  end

  # Always editable planned grids: if day has no saved planned lines, seed from weekly book
  # (in-memory / form only until autosave).
  defp seed_planned_details_from_book(day, company_id, date) do
    details = day.egg_stock_day_details || []
    dow = Date.day_of_week(date)

    details =
      seed_section_from_book(
        details,
        company_id,
        dow,
        :sales,
        EggStock.planned_sales_section(),
        EggStock.planned_sales_sections()
      )

    details =
      seed_section_from_book(
        details,
        company_id,
        dow,
        :purchase,
        EggStock.planned_purchase_section(),
        EggStock.planned_purchase_sections()
      )

    %{day | egg_stock_day_details: details}
  end

  defp seed_section_from_book(details, company_id, dow, kind, section, sections) do
    if Enum.any?(details, &(&1.section in sections)) do
      details
    else
      book_details =
        EggStock.list_dow_lines(company_id, kind, dow)
        |> Enum.with_index()
        |> Enum.map(fn {line, idx} ->
          %EggStockDayDetail{
            section: section,
            contact_id: line.contact_id,
            contact_name: line.contact_name,
            quantities: line.quantities || %{},
            group_name: line.group_name || "",
            group_position: line.group_position || 0,
            is_separator: line.is_separator || false,
            position: line.position || idx,
            ignore: false
          }
        end)

      details ++ book_details
    end
  end

  defp planned_rows_from_day(day, kind) do
    sections =
      if kind == :sales,
        do: EggStock.planned_sales_sections(),
        else: EggStock.planned_purchase_sections()

    (day.egg_stock_day_details || [])
    |> Enum.filter(&(&1.section in sections))
    |> Enum.map(fn d ->
      %{
        contact_id: d.contact_id,
        contact_name: d.contact_name,
        quantities: d.quantities || %{},
        ignore: d.ignore || false
      }
    end)
  end

  defp assign_day_form(socket, day) do
    sections = EggStock.planned_sections()

    details =
      Enum.filter(day.egg_stock_day_details || [], &(&1.section in sections))
      |> Enum.map(fn d ->
        section =
          cond do
            d.section in EggStock.planned_sales_sections() ->
              EggStock.planned_sales_section()

            d.section in EggStock.planned_purchase_sections() ->
              EggStock.planned_purchase_section()

            true ->
              d.section
          end

        %{d | section: section}
      end)

    scoped_day = %{day | egg_stock_day_details: []}

    cs =
      EggStockDay.changeset(scoped_day, %{})
      |> Ecto.Changeset.put_assoc(:egg_stock_day_details, details)

    assign(socket, form: to_form(cs))
  end

  defp grades_to_params(grades) do
    Enum.map(grades, fn g ->
      %{
        "id" => g.id,
        "name" => g.name,
        "nickname" => g.nickname,
        "position" => g.position,
        "delete" => "false"
      }
    end)
  end

  defp dow_lines_to_params(lines) do
    lines
    |> Enum.with_index()
    |> Enum.map(fn {l, idx} ->
      %{
        "id" => l.id,
        "contact_id" => l.contact_id,
        "contact_name" => l.contact_name,
        "quantities" => l.quantities || %{},
        "group_name" => l.group_name || "",
        "group_position" => l.group_position || 0,
        "position" => l.position || idx,
        "is_separator" => l.is_separator || false,
        "delete" => "false"
      }
    end)
  end

  defp compute_est_closing(opening, est_production, sales_rows, purchase_rows, grades) do
    sales_total = sum_planned_rows(sales_rows, grades)
    purchase_total = sum_planned_rows(purchase_rows, grades)

    Map.new(grades, fn g ->
      o = to_int(opening[g])
      p = to_int(est_production[g])
      s = to_int(sales_total[g])
      b = to_int(purchase_total[g])
      {g, o + p + b - s}
    end)
  end

  defp sum_planned_rows(rows, grades) do
    Enum.reduce(rows, Map.new(grades, &{&1, 0}), fn row, acc ->
      quantities = row[:quantities] || row["quantities"] || %{}
      Map.merge(acc, quantities, fn _k, v1, v2 -> to_int(v1) + to_int(v2) end)
    end)
  end

  defp compute_est_closing_from_params(opening, est_production, params, grades) do
    details = params["egg_stock_day_details"] || %{}

    {sales_total, purchase_total} =
      Enum.reduce(details, {Map.new(grades, &{&1, 0}), Map.new(grades, &{&1, 0})}, fn {_k, detail},
                                                                                      {sales,
                                                                                       purchases} ->
        if detail["is_separator"] in [true, "true"] do
          {sales, purchases}
        else
          quantities = detail["quantities"] || %{}

          case detail["section"] do
            s when s in ["planned_order", "actual_order"] ->
              {Map.merge(sales, quantities, fn _k, v1, v2 -> to_int(v1) + to_int(v2) end),
               purchases}

            s when s in ["planned_purchase", "actual_purchase"] ->
              {sales,
               Map.merge(purchases, quantities, fn _k, v1, v2 -> to_int(v1) + to_int(v2) end)}

            _ ->
              {sales, purchases}
          end
        end
      end)

    Map.new(grades, fn g ->
      o = to_int(opening[g])
      p = to_int(est_production[g])
      s = to_int(sales_total[g])
      b = to_int(purchase_total[g])
      {g, o + p + b - s}
    end)
  end

  defp detail_line_locked?(section, contact_id, actual_sales, actual_purchases) do
    cond do
      contact_id in [nil, ""] ->
        false

      section in EggStock.planned_sales_sections() ->
        contact_has_issued_docs?(actual_sales, contact_id)

      section in EggStock.planned_purchase_sections() ->
        contact_has_issued_docs?(actual_purchases, contact_id)

      true ->
        false
    end
  end

  defp contact_has_issued_docs?(rows, contact_id) do
    cid = to_string(contact_id)

    Enum.any?(rows || [], fn row ->
      to_string(row.contact_id) == cid and (row.doc_links || []) != []
    end)
  end

  defp locked_contact_ids(rows) do
    (rows || [])
    |> Enum.filter(fn row -> (row.doc_links || []) != [] end)
    |> Enum.map(&to_string(&1.contact_id))
    |> MapSet.new()
  end

  # contact_id string => list of {doc_type, doc_id}
  defp docs_by_contact(rows) do
    (rows || [])
    |> Enum.filter(fn row -> row.contact_id not in [nil, ""] and (row.doc_links || []) != [] end)
    |> Enum.reduce(%{}, fn row, acc ->
      key = to_string(row.contact_id)
      existing = Map.get(acc, key, [])
      Map.put(acc, key, Enum.uniq(existing ++ (row.doc_links || [])))
    end)
  end

  # --- Events ---

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    socket = flush_autosave(socket)

    socket =
      socket
      |> assign(active_tab: tab)
      |> then(fn s ->
        if tab in ["weekly_sales", "weekly_purchases"] do
          assign(s, dow: Date.day_of_week(s.assigns.date))
        else
          s
        end
      end)
      |> load_tab_data(tab)

    {:noreply, socket}
  end

  def handle_event("nav_date", %{"dir" => dir}, socket) do
    socket = flush_autosave(socket)
    date = socket.assigns.date
    new_date = if dir == "prev", do: Date.add(date, -1), else: Date.add(date, 1)

    {:noreply,
     push_patch(socket,
       to:
         ~p"/companies/#{socket.assigns.current_company.id}/egg_stock/#{Date.to_iso8601(new_date)}"
     )}
  end

  def handle_event("goto_date", %{"date" => date_str}, socket)
      when is_binary(date_str) and date_str != "" do
    case Date.from_iso8601(date_str) do
      {:ok, date} ->
        if Date.compare(date, socket.assigns.date) == :eq do
          {:noreply, socket}
        else
          socket = flush_autosave(socket)

          {:noreply,
           socket
           |> assign(active_tab: "now")
           |> push_patch(
             to: ~p"/companies/#{socket.assigns.current_company.id}/egg_stock/#{date_str}"
           )}
        end

      {:error, _} ->
        {:noreply, socket}
    end
  end

  def handle_event("goto_date", _params, socket), do: {:noreply, socket}

  def handle_event("select_dow", %{"dow" => dow_str}, socket) do
    socket = flush_autosave(socket)
    dow = String.to_integer(dow_str)
    kind = socket.assigns.dow_kind

    {:noreply,
     socket
     |> assign(dow: dow)
     |> load_weekly_tab(kind)}
  end

  # --- Now tab: validate/save ---

  def handle_event(
        "validate",
        %{
          "_target" => ["egg_stock_day", "egg_stock_day_details", _idx, "contact_name"],
          "egg_stock_day" => params
        },
        socket
      ) do
    params = resolve_detail_contacts(params, socket)
    validate_day(params, socket)
  end

  def handle_event("validate", %{"egg_stock_day" => params}, socket) do
    validate_day(params, socket)
  end

  def handle_event("save", %{"egg_stock_day" => _params}, socket) do
    {:noreply, socket}
  end

  def handle_event("add_detail", %{"section" => section} = params, socket) do
    cs = socket.assigns.form.source
    existing = Ecto.Changeset.get_assoc(cs, :egg_stock_day_details)
    separator? = params["separator"] in ["true", true]

    section_count =
      Enum.count(existing, &(Ecto.Changeset.get_field(&1, :section) == section))

    new_detail = %EggStockDayDetail{
      section: section,
      quantities: %{},
      group_name: "",
      group_position: 0,
      is_separator: separator?,
      position: section_count,
      contact_name: if(separator?, do: "", else: nil),
      _persistent_id: Enum.count(existing)
    }

    cs =
      cs
      |> Ecto.Changeset.put_assoc(:egg_stock_day_details, existing ++ [new_detail])
      |> Map.put(:action, :validate)

    params = changeset_to_params(cs)
    socket = assign(socket, form: to_form(cs))
    socket = schedule_autosave(socket, {:day, params})
    {:noreply, socket}
  end

  def handle_event("move_detail", %{"index" => idx_str, "dir" => dir}, socket) do
    idx = String.to_integer(idx_str)
    cs = socket.assigns.form.source
    details = Ecto.Changeset.get_assoc(cs, :egg_stock_day_details)
    detail = Enum.at(details, idx)

    if is_nil(detail) do
      {:noreply, socket}
    else
      section = Ecto.Changeset.get_field(detail, :section)

      section_idxs =
        details
        |> Enum.with_index()
        |> Enum.filter(fn {d, _} -> Ecto.Changeset.get_field(d, :section) == section end)
        |> Enum.map(fn {_, i} -> i end)

      pos_in_section = Enum.find_index(section_idxs, &(&1 == idx))

      swap_pos =
        case dir do
          "up" -> if pos_in_section && pos_in_section > 0, do: pos_in_section - 1
          "down" -> if pos_in_section && pos_in_section < length(section_idxs) - 1, do: pos_in_section + 1
          _ -> nil
        end

      if is_nil(swap_pos) do
        {:noreply, socket}
      else
        other_idx = Enum.at(section_idxs, swap_pos)
        a = Enum.at(details, idx)
        b = Enum.at(details, other_idx)
        details = details |> List.replace_at(idx, b) |> List.replace_at(other_idx, a)

        # Renumber positions within section
        details =
          renumber_section_positions(details, section)

        cs =
          cs
          |> Ecto.Changeset.put_assoc(:egg_stock_day_details, details)
          |> Map.put(:action, :validate)

        params = changeset_to_params(cs)
        socket = assign(socket, form: to_form(cs))
        socket = schedule_autosave(socket, {:day, params})
        {:noreply, socket}
      end
    end
  end

  def handle_event("delete_detail", %{"index" => index}, socket) do
    index = String.to_integer(index)
    cs = socket.assigns.form.source
    details = Ecto.Changeset.get_assoc(cs, :egg_stock_day_details)
    detail_cs = Enum.at(details, index)

    if is_nil(detail_cs) do
      {:noreply, socket}
    else
      section = Ecto.Changeset.get_field(detail_cs, :section)
      contact_id = Ecto.Changeset.get_field(detail_cs, :contact_id)

      locked? =
        detail_line_locked?(
          section,
          contact_id,
          socket.assigns[:actual_sales] || [],
          socket.assigns[:actual_purchases] || []
        )

      if locked? do
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Cannot delete: invoice or receipt already issued for this contact today")
         )}
      else
        details = List.delete_at(details, index)

        cs =
          cs
          |> Ecto.Changeset.put_assoc(:egg_stock_day_details, details)
          |> Map.put(:action, :validate)

        params = changeset_to_params(cs)
        socket = assign(socket, form: to_form(cs))

        socket =
          if socket.assigns[:est_production] do
            opening =
              if socket.assigns.is_future,
                do: socket.assigns.est_opening,
                else: socket.assigns.day.opening_bal

            est_closing =
              compute_est_closing_from_params(
                opening,
                socket.assigns.est_production,
                params,
                socket.assigns.grade_names
              )

            assign(socket, est_closing: est_closing)
          else
            socket
          end

        socket = schedule_autosave(socket, {:day, params})
        {:noreply, socket}
      end
    end
  end

  # --- Weekly book events ---

  def handle_event(
        "validate_dow",
        %{
          "_target" => ["dow_lines", _idx, "contact_name"],
          "dow_lines" => params
        },
        socket
      ) do
    params_list = resolve_dow_contacts(params_to_list(params), socket)
    validate_dow(params_list, socket)
  end

  def handle_event("validate_dow", %{"dow_lines" => params}, socket) do
    validate_dow(params_to_list(params), socket)
  end

  def handle_event("validate_dow", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("add_dow_line", params, socket) do
    separator? = params["separator"] in ["true", true]
    visible = Enum.reject(socket.assigns.dow_params, &(&1["delete"] == "true"))

    new_line = %{
      "id" => "",
      "contact_id" => "",
      "contact_name" => "",
      "quantities" => %{},
      "group_name" => "",
      "group_position" => 0,
      "position" => length(visible),
      "is_separator" => separator?,
      "delete" => "false"
    }

    params = socket.assigns.dow_params ++ [new_line]
    socket = assign(socket, dow_params: params)

    socket =
      if separator? do
        schedule_autosave(socket, {:dow, params})
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_event("delete_dow_line", %{"index" => idx_str}, socket) do
    idx = String.to_integer(idx_str)
    params = socket.assigns.dow_params
    line = Enum.at(params, idx)

    params =
      if line["id"] && line["id"] != "" do
        List.replace_at(params, idx, Map.put(line, "delete", "true"))
      else
        List.delete_at(params, idx)
      end

    params = renumber_dow_positions(params)
    socket = assign(socket, dow_params: params)
    socket = schedule_autosave(socket, {:dow, params})
    {:noreply, socket}
  end

  def handle_event("move_dow_line", %{"index" => idx_str, "dir" => dir}, socket) do
    idx = String.to_integer(idx_str)
    params = socket.assigns.dow_params

    # Work on visible indices only
    visible =
      params
      |> Enum.with_index()
      |> Enum.reject(fn {line, _} -> line["delete"] == "true" end)

    vis_pos = Enum.find_index(visible, fn {_, i} -> i == idx end)

    swap_vis =
      case dir do
        "up" -> if vis_pos && vis_pos > 0, do: vis_pos - 1
        "down" -> if vis_pos && vis_pos < length(visible) - 1, do: vis_pos + 1
        _ -> nil
      end

    if is_nil(swap_vis) do
      {:noreply, socket}
    else
      {_, other_idx} = Enum.at(visible, swap_vis)
      a = Enum.at(params, idx)
      b = Enum.at(params, other_idx)
      params = params |> List.replace_at(idx, b) |> List.replace_at(other_idx, a)
      params = renumber_dow_positions(params)

      socket =
        socket
        |> assign(dow_params: params)
        |> schedule_autosave({:dow, params})

      {:noreply, socket}
    end
  end

  # --- Settings events ---

  def handle_event("change_lookback_days", %{"lookback_days" => days_str}, socket) do
    days = String.to_integer(days_str)
    setting = Enum.find(socket.assigns.settings, &(&1.code == "lookback-days"))
    if setting, do: Sys.update_setting(setting, days_str)

    {:noreply, assign(socket, lookback_days: days)}
  end

  def handle_event("change_autosave_delay", %{"autosave_delay" => delay_str}, socket) do
    delay = String.to_integer(delay_str)
    setting = Enum.find(socket.assigns.settings, &(&1.code == "autosave-delay"))
    if setting, do: Sys.update_setting(setting, delay_str)

    {:noreply, assign(socket, autosave_delay: delay)}
  end

  def handle_event("validate_grades", %{"grades" => params}, socket) do
    {:noreply, assign(socket, grades_params: params_to_grades_list(params))}
  end

  def handle_event("save_grades", %{"grades" => params}, socket) do
    grades_list = params_to_grades_list(params)

    case EggStock.save_grades(socket.assigns.current_company.id, grades_list) do
      {:ok, _} ->
        grades = EggStock.list_grades(socket.assigns.current_company.id)
        grade_names = Enum.map(grades, & &1.name)
        grade_labels = Map.new(grades, fn g -> {g.name, g.nickname || g.name} end)

        {:noreply,
         socket
         |> assign(
           grades: grades,
           grade_names: grade_names,
           grade_labels: grade_labels,
           grades_params: grades_to_params(grades)
         )
         |> put_flash(:info, gettext("Grades saved."))}

      {:error, _, _cs, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to save grades"))}
    end
  end

  def handle_event("add_grade", _, socket) do
    params = socket.assigns.grades_params
    next_pos = length(params)

    new_grade = %{
      "id" => "",
      "name" => "",
      "nickname" => "",
      "position" => next_pos,
      "delete" => "false"
    }

    {:noreply, assign(socket, grades_params: params ++ [new_grade])}
  end

  def handle_event("delete_grade", %{"index" => idx_str}, socket) do
    idx = String.to_integer(idx_str)
    params = socket.assigns.grades_params
    grade = Enum.at(params, idx)

    params =
      if grade["id"] && grade["id"] != "" do
        List.replace_at(params, idx, Map.put(grade, "delete", "true"))
      else
        List.delete_at(params, idx)
      end

    {:noreply, assign(socket, grades_params: params)}
  end

  def handle_event("move_grade", %{"index" => idx_str, "dir" => dir}, socket) do
    idx = String.to_integer(idx_str)
    params = socket.assigns.grades_params
    visible = Enum.with_index(params) |> Enum.reject(fn {g, _} -> g["delete"] == "true" end)
    vis_pos = Enum.find_index(visible, fn {_, i} -> i == idx end)

    swap_idx =
      case dir do
        "up" -> if vis_pos > 0, do: elem(Enum.at(visible, vis_pos - 1), 1)
        "down" -> if vis_pos < length(visible) - 1, do: elem(Enum.at(visible, vis_pos + 1), 1)
      end

    params =
      if swap_idx do
        a = Enum.at(params, idx)
        b = Enum.at(params, swap_idx)
        params |> List.replace_at(idx, b) |> List.replace_at(swap_idx, a)
      else
        params
      end

    {:noreply, assign(socket, grades_params: params)}
  end

  # --- Helpers ---

  defp renumber_section_positions(details, section) do
    {details, _} =
      Enum.map_reduce(Enum.with_index(details), 0, fn {d, i}, pos ->
        if Ecto.Changeset.get_field(d, :section) == section do
          d = Ecto.Changeset.put_change(d, :position, pos)
          {{d, i}, pos + 1}
        else
          {{d, i}, pos}
        end
      end)

    Enum.map(details, fn {d, _} -> d end)
  end

  defp renumber_dow_positions(params) do
    {params, _} =
      Enum.map_reduce(params, 0, fn line, pos ->
        if line["delete"] == "true" do
          {line, pos}
        else
          {Map.put(line, "position", pos), pos + 1}
        end
      end)

    params
  end

  defp changeset_to_params(cs) do
    details =
      Ecto.Changeset.get_assoc(cs, :egg_stock_day_details)
      |> Enum.with_index()
      |> Enum.map(fn {d, i} ->
        {to_string(i),
         %{
           "id" => Ecto.Changeset.get_field(d, :id),
           "section" => Ecto.Changeset.get_field(d, :section),
           "contact_id" => Ecto.Changeset.get_field(d, :contact_id),
           "contact_name" => Ecto.Changeset.get_field(d, :contact_name),
           "quantities" => Ecto.Changeset.get_field(d, :quantities) || %{},
           "group_name" => Ecto.Changeset.get_field(d, :group_name) || "",
           "group_position" => Ecto.Changeset.get_field(d, :group_position) || 0,
           "is_separator" => Ecto.Changeset.get_field(d, :is_separator) || false,
           "position" => Ecto.Changeset.get_field(d, :position) || i,
           "_persistent_id" => i
         }}
      end)
      |> Map.new()

    %{
      "egg_stock_day_details" => details,
      "closing_bal" => Ecto.Changeset.get_field(cs, :closing_bal) || %{},
      "expired" => Ecto.Changeset.get_field(cs, :expired) || %{},
      "ungraded_bal" => to_string(Ecto.Changeset.get_field(cs, :ungraded_bal) || 0),
      "note" => Ecto.Changeset.get_field(cs, :note) || ""
    }
  end

  defp dtl_line_qty_total(dtl, grades) do
    Enum.reduce(grades, 0, fn g, acc ->
      acc + to_int((dtl[:quantities].value || %{})[g])
    end)
  end

  # --- Autosave ---

  @impl true
  def handle_info({:autosave, {:day, params}}, socket) do
    socket = assign(socket, save_status: :saving)
    do_save_day(params, socket)
  end

  def handle_info({:autosave, {:dow, params}}, socket) do
    socket = assign(socket, save_status: :saving)
    do_save_dow(params, socket)
  end

  def handle_info(:clear_save_status, socket) do
    {:noreply, assign(socket, save_status: nil)}
  end

  defp schedule_autosave(socket, payload) do
    if timer = socket.assigns[:autosave_timer], do: Process.cancel_timer(timer)
    delay = socket.assigns.autosave_delay * 1_000
    timer = Process.send_after(self(), {:autosave, payload}, delay)
    assign(socket, autosave_timer: timer, autosave_params: payload)
  end

  defp flush_autosave(socket) do
    if timer = socket.assigns[:autosave_timer] do
      Process.cancel_timer(timer)

      case socket.assigns[:autosave_params] do
        {:day, params} ->
          {:noreply, socket} = do_save_day(params, socket)
          assign(socket, autosave_timer: nil, autosave_params: nil)

        {:dow, params} ->
          {:noreply, socket} = do_save_dow(params, socket)
          assign(socket, autosave_timer: nil, autosave_params: nil)

        _ ->
          assign(socket, autosave_timer: nil, autosave_params: nil)
      end
    else
      socket
    end
  end

  defp do_save_day(params, socket) do
    day = socket.assigns.day
    planned = EggStock.planned_sections()

    all_other_details =
      day.egg_stock_day_details
      |> Enum.filter(fn d -> d.section not in planned end)
      |> Enum.with_index()
      |> Enum.map(fn {d, i} ->
        {to_string(i),
         %{
           "id" => d.id,
           "section" => d.section,
           "contact_id" => d.contact_id,
           "contact_name" => d.contact_name,
           "quantities" => d.quantities,
           "_persistent_id" => i
         }}
      end)
      |> Map.new()

    current_details = params["egg_stock_day_details"] || %{}
    offset = map_size(all_other_details)

    merged_details =
      current_details
      |> Enum.with_index(offset)
      |> Enum.map(fn {{_k, v}, i} -> {to_string(i), v} end)
      |> Map.new()
      |> Map.merge(all_other_details)

    params = Map.put(params, "egg_stock_day_details", merged_details)

    persisted_details = Enum.filter(day.egg_stock_day_details, & &1.id)
    clean_day = %{day | egg_stock_day_details: persisted_details}

    case EggStock.save_day(
           clean_day,
           params,
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, updated_day} ->
        updated_day =
          updated_day
          |> FullCircle.Repo.preload([egg_stock_day_details: EggStock.__day_details_query__()],
            force: true
          )

        Process.send_after(self(), :clear_save_status, 2_000)

        {:noreply,
         socket
         |> assign(day: updated_day, save_status: :saved)
         |> assign_day_form(updated_day)}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, assign(socket, form: to_form(cs), save_status: :error)}

      :not_authorise ->
        {:noreply,
         assign(socket, save_status: :error)
         |> put_flash(:error, gettext("You are not authorised to perform this action"))}
    end
  end

  defp do_save_dow(params, socket) do
    case EggStock.save_dow_lines(
           socket.assigns.current_company.id,
           socket.assigns.dow_kind,
           socket.assigns.dow,
           params,
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, lines} ->
        Process.send_after(self(), :clear_save_status, 2_000)

        {:noreply,
         socket
         |> assign(
           dow_lines: lines,
           dow_params: dow_lines_to_params(lines),
           save_status: :saved
         )}

      {:error, _cs} ->
        {:noreply, assign(socket, save_status: :error)}

      :not_authorise ->
        {:noreply,
         assign(socket, save_status: :error)
         |> put_flash(:error, gettext("You are not authorised to perform this action"))}
    end
  end

  defp resolve_detail_contacts(params, socket) do
    details = params["egg_stock_day_details"] || %{}

    details =
      Enum.map(details, fn {k, v} ->
        name = String.trim(v["contact_name"] || "")

        if name != "" do
          contact =
            Accounting.get_contact_by_name(
              name,
              socket.assigns.current_company,
              socket.assigns.current_user
            )

          {k, Map.put(v, "contact_id", if(contact, do: contact.id))}
        else
          {k, Map.put(v, "contact_id", nil)}
        end
      end)
      |> Map.new()

    Map.put(params, "egg_stock_day_details", details)
  end

  defp resolve_dow_contacts(params_list, socket) do
    Enum.map(params_list, fn v ->
      name = String.trim(v["contact_name"] || "")

      if name != "" do
        contact =
          Accounting.get_contact_by_name(
            name,
            socket.assigns.current_company,
            socket.assigns.current_user
          )

        Map.put(v, "contact_id", if(contact, do: contact.id))
      else
        Map.put(v, "contact_id", nil)
      end
    end)
  end

  defp validate_day(params, socket) do
    day = socket.assigns.day
    sections = EggStock.planned_sections()

    scoped_details =
      Enum.filter(day.egg_stock_day_details, &(&1.id && &1.section in sections))

    scoped_day = %{day | egg_stock_day_details: scoped_details}

    cs =
      EggStockDay.changeset(scoped_day, params)
      |> Map.put(:action, :validate)

    socket = assign(socket, form: to_form(cs))

    socket =
      if socket.assigns[:est_production] do
        opening =
          if socket.assigns.is_future,
            do: socket.assigns.est_opening,
            else: socket.assigns.day.opening_bal

        est_closing =
          compute_est_closing_from_params(
            opening,
            socket.assigns.est_production,
            params,
            socket.assigns.grade_names
          )

        assign(socket, est_closing: est_closing)
      else
        socket
      end

    socket = schedule_autosave(socket, {:day, params})

    {:noreply, socket}
  end

  defp validate_dow(params_list, socket) do
    socket =
      socket
      |> assign(dow_params: params_list)
      |> schedule_autosave({:dow, params_list})

    {:noreply, socket}
  end

  defp params_to_list(params) when is_map(params) do
    params
    |> Enum.sort_by(fn {k, _} ->
      case Integer.parse(to_string(k)) do
        {n, _} -> n
        :error -> 0
      end
    end)
    |> Enum.map(fn {_k, v} -> v end)
  end

  defp params_to_list(params) when is_list(params), do: params

  defp params_to_grades_list(params) when is_map(params) do
    params
    |> Enum.sort_by(fn {k, _v} -> String.to_integer(k) end)
    |> Enum.map(fn {_k, v} -> v end)
  end

  defp params_to_grades_list(params) when is_list(params), do: params

  defp to_int(nil), do: 0
  defp to_int(""), do: 0
  defp to_int(v) when is_integer(v), do: v
  defp to_int(v) when is_float(v), do: round(v)

  defp to_int(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp display_val(nil), do: 0
  defp display_val(v) when is_float(v), do: Float.round(v, 2)
  defp display_val(v), do: to_int(v)

  defp to_number(nil), do: 0
  defp to_number(v) when is_float(v), do: v
  defp to_number(v) when is_integer(v), do: v

  defp to_number(v) when is_binary(v) do
    case Float.parse(v) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp actual_total(rows, grade) do
    Enum.reduce(rows, 0, fn row, acc ->
      acc + to_int((row.quantities || %{})[grade])
    end)
  end

  defp sum_quantities(details, section, grade) when is_list(details) do
    details
    |> Enum.filter(fn d ->
      d.section == section and Map.get(d, :is_separator) != true
    end)
    |> Enum.reduce(0, fn d, acc ->
      acc + to_int((d.quantities || %{})[grade])
    end)
  end

  defp dow_label(1), do: gettext("Mon")
  defp dow_label(2), do: gettext("Tue")
  defp dow_label(3), do: gettext("Wed")
  defp dow_label(4), do: gettext("Thu")
  defp dow_label(5), do: gettext("Fri")
  defp dow_label(6), do: gettext("Sat")
  defp dow_label(7), do: gettext("Sun")

  # --- Render ---

  defp save_status(%{status: nil} = assigns), do: ~H""

  defp save_status(%{status: :saving} = assigns) do
    ~H"""
    <span class="text-sm text-gray-500 animate-pulse">{gettext("Saving...")}</span>
    """
  end

  defp save_status(%{status: :saved} = assigns) do
    ~H"""
    <span class="text-sm text-green-600">{gettext("Saved")}</span>
    """
  end

  defp save_status(%{status: :error} = assigns) do
    ~H"""
    <span class="text-sm text-red-600">{gettext("Save failed")}</span>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto w-10/12 mb-10">
      <div class="text-center mb-2">
        <span class="text-xl font-bold">{gettext("Egg Stock")}</span>
      </div>

      <%!-- Date selector --%>
      <div class="flex items-center justify-center gap-1 mb-4">
        <button
          type="button"
          phx-click="nav_date"
          phx-value-dir="prev"
          class="px-2 py-1 text-lg font-bold text-gray-600 hover:text-blue-600"
        >
          <.icon name="hero-chevron-left" class="h-5 w-5" />
        </button>
        <form phx-change="goto_date" class="inline-flex items-center">
          <input
            type="date"
            name="date"
            id="egg-stock-date"
            value={Date.to_iso8601(@date)}
            class="text-lg font-semibold border border-gray-300 rounded px-2 py-1 cursor-pointer hover:border-blue-400 focus:outline-none focus:ring-1 focus:ring-blue-500"
            title={gettext("Pick a date")}
          />
        </form>
        <button
          type="button"
          phx-click="nav_date"
          phx-value-dir="next"
          class="px-2 py-1 text-lg font-bold text-gray-600 hover:text-blue-600"
        >
          <.icon name="hero-chevron-right" class="h-5 w-5" />
        </button>
        <.save_status status={@save_status} />
      </div>

      <%!-- Tabs --%>
      <div class="flex flex-wrap items-end justify-center gap-x-0.5 gap-y-0 mb-3 border-b border-gray-200">
        <.tab_button tab="now" active={@active_tab} label={gettext("Stock")} />
        <.tab_button tab="weekly_sales" active={@active_tab} label={gettext("Weekly Sales")} />
        <.tab_button tab="weekly_purchases" active={@active_tab} label={gettext("Weekly Purchases")} />
        <.tab_button tab="estimated" active={@active_tab} label={gettext("Estimated")} />
        <.tab_button tab="settings" active={@active_tab} label={gettext("Settings")} />
        <.link
          navigate={~p"/companies/#{@current_company.id}/egg_stock/production_report"}
          class="px-2 py-1 text-xs text-blue-600 hover:text-blue-800 hover:underline self-center ml-2"
        >
          {gettext("Production Report")}
        </.link>
      </div>

      <div :if={@active_tab == "now"}>
        <.now_tab
          form={@form}
          day={@day}
          date={@date}
          grades={@grade_names}
          grade_labels={@grade_labels}
          editable={@editable}
          is_future={@is_future}
          actual_sales={@actual_sales}
          actual_purchases={@actual_purchases}
          harvested={@harvested}
          yesterday_ug={@yesterday_ug}
          est_opening={@est_opening}
          est_production={@est_production}
          est_harvest={@est_harvest}
          est_closing={@est_closing}
          current_company={@current_company}
          current_user={@current_user}
        />
      </div>

      <div :if={@active_tab in ["weekly_sales", "weekly_purchases"]}>
        <.weekly_tab
          kind={@dow_kind}
          dow={@dow}
          dow_params={@dow_params}
          grades={@grade_names}
          grade_labels={@grade_labels}
          current_company={@current_company}
          current_user={@current_user}
        />
      </div>

      <div :if={@active_tab == "estimated"}>
        <.estimated_tab
          forecast={@forecast}
          grades={@grade_names}
          grade_labels={@grade_labels}
          date={@date}
        />
      </div>

      <div :if={@active_tab == "settings"}>
        <.settings_tab
          grades_params={@grades_params}
          lookback_days={@lookback_days}
          autosave_delay={@autosave_delay}
          current_company={@current_company}
          current_user={@current_user}
        />
      </div>
    </div>
    """
  end

  defp tab_button(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="switch_tab"
      phx-value-tab={@tab}
      class={"px-2.5 py-1 text-xs font-medium -mb-px #{if @tab == @active, do: "border-b-2 border-blue-500 text-blue-600", else: "border-b-2 border-transparent text-gray-500 hover:text-gray-700"}"}
    >
      {@label}
    </button>
    """
  end

  # --- Weekly Tab ---

  defp weekly_tab(assigns) do
    ~H"""
    <div class="flex flex-col items-center">
    <div class="w-fit max-w-full">
    <div class="mb-3 flex flex-wrap items-center gap-2">
      <span class="text-sm font-semibold text-gray-600">
        {if @kind == "sales", do: gettext("Sales book"), else: gettext("Purchase book")}
      </span>
      <button
        :for={d <- 1..7}
        type="button"
        phx-click="select_dow"
        phx-value-dow={d}
        class={"px-3 py-1 text-sm rounded border #{if d == @dow, do: "bg-blue-600 text-white border-blue-600", else: "bg-white text-gray-700 border-gray-300 hover:bg-gray-50"}"}
      >
        {dow_label(d)}
      </button>
    </div>

    <.form for={%{}} id="dow-form" autocomplete="off" phx-change="validate_dow" class="w-fit max-w-full">
      <div class="flex gap-1 mb-1">
        <div class="w-12 shrink-0"></div>
        <div class="w-56 text-sm font-semibold text-gray-600">{gettext("Contact")}</div>
        <div :for={grade <- @grades} class="w-20 text-center text-sm font-semibold text-gray-600">
          {@grade_labels[grade]}
        </div>
        <div class="w-20 text-center text-sm font-semibold text-gray-600">{gettext("Total")}</div>
      </div>

      <div :for={{line, idx} <- Enum.with_index(@dow_params)}>
        <input type="hidden" name={"dow_lines[#{idx}][id]"} value={line["id"]} />
        <input type="hidden" name={"dow_lines[#{idx}][delete]"} value={line["delete"] || "false"} />
        <input type="hidden" name={"dow_lines[#{idx}][contact_id]"} value={line["contact_id"]} />
        <input
          :if={line["is_separator"] not in [true, "true"]}
          type="hidden"
          name={"dow_lines[#{idx}][group_name]"}
          value={line["group_name"] || ""}
        />
        <input
          type="hidden"
          name={"dow_lines[#{idx}][group_position]"}
          value={line["group_position"] || 0}
        />
        <input type="hidden" name={"dow_lines[#{idx}][position]"} value={line["position"] || idx} />
        <input
          type="hidden"
          name={"dow_lines[#{idx}][is_separator]"}
          value={to_string(line["is_separator"] in [true, "true"])}
        />

        <div :if={line["delete"] != "true" and line["is_separator"] in [true, "true"]} class="flex items-center gap-1 my-2">
          <div class="flex items-center w-12 shrink-0">
            <button type="button" phx-click="move_dow_line" phx-value-index={idx} phx-value-dir="up" class="text-gray-400 hover:text-gray-700" title={gettext("Move up")}>
              <.icon name="hero-chevron-up" class="h-3 w-3" />
            </button>
            <button type="button" phx-click="move_dow_line" phx-value-index={idx} phx-value-dir="down" class="text-gray-400 hover:text-gray-700" title={gettext("Move down")}>
              <.icon name="hero-chevron-down" class="h-3 w-3" />
            </button>
          </div>
          <div class="flex-1 border-t-2 border-dashed border-gray-400"></div>
          <input type="hidden" name={"dow_lines[#{idx}][contact_name]"} value="" />
          <input
            type="text"
            name={"dow_lines[#{idx}][group_name]"}
            value={line["group_name"] || ""}
            placeholder={gettext("Label (optional)")}
            class="w-56 text-xs border rounded px-2 py-0.5 text-gray-600"
          />
          <div class="flex-1 border-t-2 border-dashed border-gray-400"></div>
          <button type="button" phx-click="delete_dow_line" phx-value-index={idx} class="text-red-500 hover:text-red-700" title={gettext("Delete separator")}>
            <.icon name="hero-trash" class="h-4 w-4" />
          </button>
        </div>

        <div :if={line["delete"] != "true" and line["is_separator"] not in [true, "true"]} class="flex items-center gap-1 mb-1">
          <div class="flex items-center w-12 shrink-0">
            <button type="button" phx-click="move_dow_line" phx-value-index={idx} phx-value-dir="up" class="text-gray-400 hover:text-gray-700" title={gettext("Move up")}>
              <.icon name="hero-chevron-up" class="h-3 w-3" />
            </button>
            <button type="button" phx-click="move_dow_line" phx-value-index={idx} phx-value-dir="down" class="text-gray-400 hover:text-gray-700" title={gettext("Move down")}>
              <.icon name="hero-chevron-down" class="h-3 w-3" />
            </button>
          </div>
          <input
            type="text"
            id={"dow-contact-#{@kind}-#{idx}"}
            name={"dow_lines[#{idx}][contact_name]"}
            value={line["contact_name"]}
            class="w-56 border rounded px-2 py-1"
            phx-hook="tributeAutoComplete"
            url={"/list/companies/#{@current_company.id}/#{@current_user.id}/autocomplete?schema=contact&name="}
          />
          <input
            :for={grade <- @grades}
            type="number"
            name={"dow_lines[#{idx}][quantities][#{grade}]"}
            value={(line["quantities"] || %{})[grade] || ""}
            class="w-20 text-center border rounded px-1 py-1"
          />
          <div class="w-20 text-center font-semibold py-1">
            {Enum.reduce(@grades, 0, fn g, acc -> acc + to_int((line["quantities"] || %{})[g]) end)}
          </div>
          <button
            type="button"
            phx-click="delete_dow_line"
            phx-value-index={idx}
            class="text-red-500 hover:text-red-700"
            title={gettext("Delete")}
          >
            <.icon name="hero-trash" class="h-4 w-4" />
          </button>
        </div>
      </div>

      <div class="flex gap-1 mt-1 font-semibold text-sm text-gray-700 border-t pt-1">
        <div class="w-12 shrink-0"></div>
        <div class="w-56 text-right">{gettext("Total")}</div>
        <div :for={grade <- @grades} class="w-20 text-center">
          {Enum.reduce(@dow_params, 0, fn line, acc ->
            if line["delete"] == "true" or line["is_separator"] in [true, "true"],
              do: acc,
              else: acc + to_int((line["quantities"] || %{})[grade])
          end)}
        </div>
        <div class="w-20 text-center">
          {Enum.reduce(@grades, 0, fn g, acc ->
            acc +
              Enum.reduce(@dow_params, 0, fn line, a ->
                if line["delete"] == "true" or line["is_separator"] in [true, "true"],
                  do: a,
                  else: a + to_int((line["quantities"] || %{})[g])
              end)
          end)}
        </div>
      </div>
    </.form>

    <div class="mt-2 flex gap-3">
      <button
        type="button"
        phx-click="add_dow_line"
        class="text-blue-600 hover:text-blue-800 flex items-center gap-1 text-sm"
      >
        <.icon name="hero-plus-circle" class="h-5 w-5" /> {gettext("Add line")}
      </button>
      <button
        type="button"
        phx-click="add_dow_line"
        phx-value-separator="true"
        class="text-gray-600 hover:text-gray-800 flex items-center gap-1 text-sm"
      >
        <.icon name="hero-minus" class="h-5 w-5" /> {gettext("Add separator")}
      </button>
    </div>
    </div>
    </div>
    """
  end

  # --- Now Tab ---

  defp now_tab(assigns) do
    ~H"""
    <div class="flex flex-col items-center">
      <div class="w-fit max-w-full">
        <div class="flex gap-1 mb-1">
          <div class="w-12 shrink-0"></div>
          <div class="w-56"></div>
          <div :for={grade <- @grades} class="w-20 text-center text-sm font-semibold text-gray-600">
            {@grade_labels[grade]}
          </div>
          <div class="w-20 text-center text-sm font-semibold text-gray-600">{gettext("Total")}</div>
        </div>

        <%!-- Past date (read-only history) --%>
        <div :if={!@editable}>
          <.summary_row
            label={gettext("Opening")}
            grades={@grades}
            values={@day.opening_bal || %{}}
            bg="bg-gray-100"
          />

          <.actual_data_section
            title={gettext("Purchases")}
            rows={@actual_purchases}
            grades={@grades}
            bg_class="bg-emerald-50"
            title_class="text-emerald-700"
            company_id={@current_company.id}
          />

          <.actual_data_section
            title={gettext("Sales")}
            rows={@actual_sales}
            grades={@grades}
            bg_class="bg-blue-50"
            title_class="text-blue-700"
            company_id={@current_company.id}
          />

          <.form
            for={@form}
            id="day-form-readonly"
            autocomplete="off"
            phx-change="validate"
            phx-submit="save"
            class="w-fit max-w-full"
          >
            <.expired_closing_block form={@form} grades={@grades} />
            <.production_block
              day={@day}
              form={@form}
              grades={@grades}
              actual_sales={@actual_sales}
              actual_purchases={@actual_purchases}
            />
            <.harvest_ug_loss_block
              form={@form}
              day={@day}
              grades={@grades}
              harvested={@harvested}
              yesterday_ug={@yesterday_ug}
              est_harvest={nil}
              actual_sales={@actual_sales}
              actual_purchases={@actual_purchases}
            />
            <.note_block form={@form} />
          </.form>

          <div class="flex justify-end mt-2">
            <a
              href={~p"/companies/#{@current_company.id}/EggStock/#{Date.to_iso8601(@date)}/print"}
              target="_blank"
              class="text-blue-600 hover:text-blue-800 flex items-center gap-1 text-sm"
            >
              <.icon name="hero-printer" class="h-4 w-4" /> {gettext("Print Report")}
            </a>
          </div>
        </div>

        <%!-- Today / Future --%>
        <div :if={@editable}>
          <.summary_row
            :if={!@is_future}
            label={gettext("Opening")}
            grades={@grades}
            values={@day.opening_bal || %{}}
            bg="bg-gray-100"
          />
          <.summary_row
            :if={@is_future}
            label={gettext("Est Opening")}
            grades={@grades}
            values={@est_opening || %{}}
            bg="bg-gray-100"
          />

          <.form
            for={@form}
            id="day-form"
            autocomplete="off"
            phx-change="validate"
            phx-submit="save"
            class="w-fit max-w-full"
          >
            <.planned_section
              title={gettext("Planned Purchases")}
              form={@form}
              section={EggStock.planned_purchase_section()}
              grades={@grades}
              grade_labels={@grade_labels}
              current_company={@current_company}
              current_user={@current_user}
              date={@date}
              day_details={@day.egg_stock_day_details}
              locked_contact_ids={locked_contact_ids(@actual_purchases)}
              docs_by_contact={docs_by_contact(@actual_purchases)}
            />

            <.planned_section
              title={gettext("Planned Sales")}
              form={@form}
              section={EggStock.planned_sales_section()}
              grades={@grades}
              grade_labels={@grade_labels}
              current_company={@current_company}
              current_user={@current_user}
              date={@date}
              day_details={@day.egg_stock_day_details}
              locked_contact_ids={locked_contact_ids(@actual_sales)}
              docs_by_contact={docs_by_contact(@actual_sales)}
            />

            <.summary_row
              :if={@est_production}
              label={gettext("Est Production")}
              grades={@grades}
              values={@est_production}
              bg="bg-green-50"
            />

            <div :if={@is_future} class="flex gap-1 mb-1">
              <div class="w-12 shrink-0"></div>
              <div class="w-56 font-bold text-sm py-1">{gettext("Est Harvest")}</div>
              <div class="w-20 text-center border rounded px-2 py-1 bg-amber-50">{@est_harvest}</div>
            </div>

            <.summary_row
              :if={@est_closing}
              label={gettext("Est Closing")}
              grades={@grades}
              values={@est_closing}
              bg="bg-purple-50"
            />

            <div :if={!@is_future}>
              <.expired_closing_block form={@form} grades={@grades} />
              <.production_block
                day={@day}
                form={@form}
                grades={@grades}
                actual_sales={@actual_sales}
                actual_purchases={@actual_purchases}
              />
              <.harvest_ug_loss_block
                form={@form}
                day={@day}
                grades={@grades}
                harvested={@harvested}
                yesterday_ug={@yesterday_ug}
                est_harvest={@est_harvest}
                actual_sales={@actual_sales}
                actual_purchases={@actual_purchases}
              />
            </div>

            <.note_block form={@form} />
          </.form>

          <div :if={!@is_future} class="flex justify-end mt-2">
            <a
              href={~p"/companies/#{@current_company.id}/EggStock/#{Date.to_iso8601(@date)}/print"}
              target="_blank"
              class="text-blue-600 hover:text-blue-800 flex items-center gap-1 text-sm"
            >
              <.icon name="hero-printer" class="h-4 w-4" /> {gettext("Print Report")}
            </a>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp planned_section(assigns) do
    ~H"""
    <div class="mb-3 border rounded p-2">
      <div class="flex items-center gap-2 mb-1 flex-wrap">
        <h3 class="font-bold text-sm">{@title}</h3>
        <span class="text-xs text-gray-500">
          {gettext("Seeded from weekly book — edit freely for this day")}
        </span>
        <button
          type="button"
          phx-click="add_detail"
          phx-value-section={@section}
          class="text-blue-600 hover:text-blue-800"
          title={gettext("Add line")}
        >
          <.icon name="hero-plus-circle" class="h-5 w-5" />
        </button>
        <button
          type="button"
          phx-click="add_detail"
          phx-value-section={@section}
          phx-value-separator="true"
          class="text-gray-600 hover:text-gray-800 text-sm flex items-center gap-1"
          title={gettext("Add separator")}
        >
          <.icon name="hero-minus" class="h-4 w-4" /> {gettext("Separator")}
        </button>
      </div>

      <.detail_lines
        form={@form}
        section={@section}
        grades={@grades}
        grade_labels={@grade_labels}
        editable={true}
        current_company={@current_company}
        current_user={@current_user}
        date={@date}
        locked_contact_ids={@locked_contact_ids}
        docs_by_contact={@docs_by_contact}
      />
      <.section_totals details={@day_details} section={@section} grades={@grades} />
    </div>
    """
  end

  defp expired_closing_block(assigns) do
    ~H"""
    <div class="flex gap-1 mb-1">
      <div class="w-12 shrink-0"></div>
      <div class="w-56 font-bold text-sm py-1">{gettext("Expired")}</div>
      <input
        :for={grade <- @grades}
        type="number"
        name={"egg_stock_day[expired][#{grade}]"}
        value={(@form[:expired].value || %{})[grade] || ""}
        class="w-20 text-center border rounded px-1 py-1"
        phx-debounce="blur"
      />
      <div class="w-20 text-center font-semibold border rounded px-2 py-1 bg-gray-50">
        {Enum.reduce(@grades, 0, fn g, acc -> acc + to_int((@form[:expired].value || %{})[g]) end)}
      </div>
    </div>

    <div class="flex gap-1 mb-1">
      <div class="w-12 shrink-0"></div>
      <div class="w-56 font-bold text-sm py-1">{gettext("Closing")}</div>
      <input
        :for={grade <- @grades}
        type="number"
        name={"egg_stock_day[closing_bal][#{grade}]"}
        value={(@form[:closing_bal].value || %{})[grade] || ""}
        class="w-20 text-center border rounded px-1 py-1"
        phx-debounce="blur"
      />
      <div class="w-20 text-center font-semibold border rounded px-2 py-1 bg-gray-50">
        {Enum.reduce(@grades, 0, fn g, acc ->
          acc + to_int((@form[:closing_bal].value || %{})[g])
        end)}
      </div>
    </div>
    """
  end

  defp production_block(assigns) do
    productions =
      Map.new(assigns.grades, fn g ->
        o = to_int((assigns.day.opening_bal || %{})[g])
        c = to_int((assigns.form[:closing_bal].value || %{})[g])
        b = actual_total(assigns.actual_purchases, g)
        s = actual_total(assigns.actual_sales, g)
        e = to_int((assigns.form[:expired].value || %{})[g])
        {g, s + e + c - o - b}
      end)

    assigns = assign(assigns, :productions, productions)

    ~H"""
    <.summary_row label={gettext("Production")} grades={@grades} values={@productions} bg="bg-green-50" />
    """
  end

  defp harvest_ug_loss_block(assigns) do
    harvest_display =
      if assigns.harvested == 0 && assigns.est_harvest,
        do: assigns.est_harvest,
        else: assigns.harvested

    productions =
      Map.new(assigns.grades, fn g ->
        o = to_int((assigns.day.opening_bal || %{})[g])
        c = to_int((assigns.form[:closing_bal].value || %{})[g])
        b = actual_total(assigns.actual_purchases, g)
        s = actual_total(assigns.actual_sales, g)
        e = to_int((assigns.form[:expired].value || %{})[g])
        {g, s + e + c - o - b}
      end)

    harvest_plus_ug = harvest_display + assigns.yesterday_ug

    yields =
      Map.new(assigns.grades, fn g ->
        p = to_int(productions[g])
        {g, if(harvest_plus_ug > 0, do: Float.round(p / harvest_plus_ug * 100, 2), else: 0.0)}
      end)

    assigns =
      assigns
      |> assign(:harvest_display, harvest_display)
      |> assign(:yields, yields)

    ~H"""
    <div class="flex gap-1 mb-1">
      <div class="w-12 shrink-0"></div>
      <div class="w-56 font-bold text-sm py-1">{gettext("Harvest/UG/Loss")}</div>
      <div class={"w-20 text-center border rounded px-2 py-1 #{if @harvested == 0 && @est_harvest, do: "bg-purple-50", else: "bg-amber-50"}"}>
        {@harvest_display}
      </div>
      <div class="w-20 text-center border rounded px-2 py-1 bg-gray-100">{@yesterday_ug}</div>
      <input
        type="number"
        name="egg_stock_day[ungraded_bal]"
        value={@form[:ungraded_bal].value || 0}
        class="w-20 text-center border rounded px-1 py-1"
        phx-debounce="blur"
      />
      <% closing_total =
        Enum.reduce(@grades, 0, fn g, acc -> acc + to_int((@form[:closing_bal].value || %{})[g]) end) %>
      <div :if={closing_total > 0} class="flex gap-1">
        <% opening_total =
          Enum.reduce(@grades, 0, fn g, acc -> acc + to_int((@day.opening_bal || %{})[g]) end) %>
        <% sold_total =
          Enum.reduce(@grades, 0, fn g, acc -> acc + actual_total(@actual_sales, g) end) %>
        <% purchased_total =
          Enum.reduce(@grades, 0, fn g, acc -> acc + actual_total(@actual_purchases, g) end) %>
        <% expired_total =
          Enum.reduce(@grades, 0, fn g, acc -> acc + to_int((@form[:expired].value || %{})[g]) end) %>
        <% ug_today = to_int(@form[:ungraded_bal].value) %>
        <% loss =
          @harvest_display + opening_total + purchased_total + @yesterday_ug - ug_today - sold_total -
            closing_total - expired_total %>
        <div class={"w-20 text-center border rounded px-2 py-1 #{if loss < 0, do: "bg-red-100 text-red-700", else: "bg-orange-50"}"}>
          {loss}
        </div>
      </div>
    </div>
    <div class="flex gap-1 mb-2 text-xs text-gray-500">
      <div class="w-12 shrink-0"></div>
      <div class="w-56"></div>
      <div class="w-20 text-center">
        {if @harvested == 0 && @est_harvest, do: gettext("Est Harvest"), else: gettext("Harvested")}
      </div>
      <div class="w-20 text-center">{gettext("Ytd UG")}</div>
      <div class="w-20 text-center">{gettext("UG")}</div>
      <div class="w-20 text-center">{gettext("Loss")}</div>
    </div>

    <.summary_row label={gettext("Yield %")} grades={@grades} values={@yields} bg="bg-yellow-50" suffix="%" />
    """
  end

  defp note_block(assigns) do
    ~H"""
    <div class="mb-4 mt-2">
      <label class="font-bold">{gettext("Note")}</label>
      <textarea name="egg_stock_day[note]" class="block w-full border rounded p-2" rows="2">{@form[:note].value}</textarea>
    </div>
    """
  end

  defp summary_row(assigns) do
    assigns = assign_new(assigns, :suffix, fn -> "" end)

    ~H"""
    <div class="flex gap-1 mb-1">
      <div class="w-12 shrink-0"></div>
      <div class="w-56 font-bold text-sm py-1">{@label}</div>
      <div :for={grade <- @grades} class={"w-20 text-center border rounded px-2 py-1 #{@bg}"}>
        {display_val(@values[grade])}{@suffix}
      </div>
      <div class={"w-20 text-center font-semibold border rounded px-2 py-1 #{@bg}"}>
        <% total = Enum.reduce(@grades, 0, fn g, acc -> acc + to_number(@values[g]) end) %>
        {display_val(total)}{@suffix}
      </div>
    </div>
    """
  end

  defp actual_data_section(assigns) do
    ~H"""
    <div :if={@rows != []} class="mb-2">
      <h3 class={"font-bold text-sm mb-1 #{@title_class}"}>{@title}</h3>
      <div :for={row <- @rows} class={"flex gap-1 text-sm #{@bg_class}"}>
        <span class="w-12 shrink-0"></span>
        <span class="w-56 truncate flex items-center gap-1" title={row.contact_name}>
          {row.contact_name}
        </span>
        <span :for={grade <- @grades} class="w-20 text-center">
          {(row.quantities || %{})[grade] || 0}
        </span>
        <span class="w-20 text-center font-semibold">
          {Enum.reduce(@grades, 0, fn g, acc -> acc + to_int((row.quantities || %{})[g]) end)}
        </span>
        <span :for={{doc_type, doc_id} <- row.doc_links || []} class="inline-flex">
          <a
            href={doc_link_path(@company_id, doc_type, doc_id)}
            target="_blank"
            class="text-blue-600 hover:text-blue-800"
            title={doc_type}
          >
            <.icon name={doc_icon(doc_type)} class="h-3 w-3" />
          </a>
        </span>
      </div>
      <div class="flex gap-1 mt-1 font-semibold text-sm text-gray-700 border-t pt-1">
        <div class="w-12 shrink-0"></div>
        <div class="w-56 text-right">{gettext("Total")}</div>
        <div :for={grade <- @grades} class="w-20 text-center">
          {actual_total(@rows, grade)}
        </div>
        <div class="w-20 text-center">
          {Enum.reduce(@grades, 0, fn g, acc -> acc + actual_total(@rows, g) end)}
        </div>
      </div>
    </div>
    """
  end

  defp doc_link_path(company_id, "Invoice", doc_id),
    do: ~p"/companies/#{company_id}/Invoice/#{doc_id}/edit"

  defp doc_link_path(company_id, "PurInvoice", doc_id),
    do: ~p"/companies/#{company_id}/PurInvoice/#{doc_id}/edit"

  defp doc_link_path(company_id, "Receipt", doc_id),
    do: ~p"/companies/#{company_id}/Receipt/#{doc_id}/edit"

  defp doc_link_path(company_id, "Payment", doc_id),
    do: ~p"/companies/#{company_id}/Payment/#{doc_id}/edit"

  defp doc_icon("Invoice"), do: "hero-document-text-solid"
  defp doc_icon("PurInvoice"), do: "hero-document-text-solid"
  defp doc_icon("Receipt"), do: "hero-banknotes-solid"
  defp doc_icon("Payment"), do: "hero-banknotes-solid"

  defp detail_lines(assigns) do
    ~H"""
    <div>
      <.inputs_for :let={dtl} field={@form[:egg_stock_day_details]}>
        <% separator? = dtl[:is_separator].value in [true, "true"] %>
        <% contact_key =
          if dtl[:contact_id].value in [nil, ""], do: nil, else: to_string(dtl[:contact_id].value) %>
        <% issued_docs = if contact_key, do: Map.get(@docs_by_contact, contact_key, []), else: [] %>
        <% has_docs = issued_docs != [] %>
        <% locked =
          contact_key != nil and MapSet.member?(@locked_contact_ids, contact_key) %>
        <% line_editable = @editable and !locked %>

        <div :if={dtl[:section].value == @section}>
          <input :if={dtl[:id].value} type="hidden" name={dtl[:id].name} value={dtl[:id].value} />
          <input type="hidden" name={dtl[:section].name} value={@section} />
          <input type="hidden" name={dtl[:contact_id].name} value={dtl[:contact_id].value} />
          <input type="hidden" name={dtl[:_persistent_id].name} value={dtl.index} />
          <input
            :if={!separator?}
            type="hidden"
            name={"#{dtl.name}[group_name]"}
            value={dtl[:group_name].value || ""}
          />
          <input
            type="hidden"
            name={"#{dtl.name}[group_position]"}
            value={dtl[:group_position].value || 0}
          />
          <input
            type="hidden"
            name={"#{dtl.name}[is_separator]"}
            value={to_string(separator?)}
          />
          <input
            type="hidden"
            name={"#{dtl.name}[position]"}
            value={dtl[:position].value || 0}
          />

          <%!-- Separator row (label stored in group_name) --%>
          <div :if={separator?} class="flex items-center gap-1 my-2">
            <div :if={@editable} class="flex items-center w-12 shrink-0">
              <button
                type="button"
                phx-click="move_detail"
                phx-value-index={dtl.index}
                phx-value-dir="up"
                class="text-gray-400 hover:text-gray-700"
                title={gettext("Move up")}
              >
                <.icon name="hero-chevron-up" class="h-3 w-3" />
              </button>
              <button
                type="button"
                phx-click="move_detail"
                phx-value-index={dtl.index}
                phx-value-dir="down"
                class="text-gray-400 hover:text-gray-700"
                title={gettext("Move down")}
              >
                <.icon name="hero-chevron-down" class="h-3 w-3" />
              </button>
            </div>
            <div :if={!@editable} class="w-12 shrink-0"></div>
            <div class="flex-1 border-t-2 border-dashed border-gray-400"></div>
            <input type="hidden" name={dtl[:contact_name].name} value="" />
            <input
              type="text"
              name={"#{dtl.name}[group_name]"}
              value={dtl[:group_name].value || ""}
              placeholder={gettext("Label (optional)")}
              class="w-56 text-xs border rounded px-2 py-0.5 text-gray-600"
              readonly={!@editable}
            />
            <div class="flex-1 border-t-2 border-dashed border-gray-400"></div>
            <button
              :if={@editable}
              type="button"
              phx-click="delete_detail"
              phx-value-index={dtl.index}
              class="text-red-500 hover:text-red-700"
              title={gettext("Delete separator")}
            >
              <.icon name="hero-trash" class="h-4 w-4" />
            </button>
          </div>

          <%!-- Contact line --%>
          <div
            :if={!separator?}
            class={"flex items-center gap-1 mb-1 #{if locked, do: "opacity-75"}"}
            title={
              if locked,
                do: gettext("Linked to a document — edit quantities on the document")
            }
          >
            <div :if={@editable} class="flex items-center w-12 shrink-0">
              <button
                type="button"
                phx-click="move_detail"
                phx-value-index={dtl.index}
                phx-value-dir="up"
                class="text-gray-400 hover:text-gray-700"
                title={gettext("Move up")}
              >
                <.icon name="hero-chevron-up" class="h-3 w-3" />
              </button>
              <button
                type="button"
                phx-click="move_detail"
                phx-value-index={dtl.index}
                phx-value-dir="down"
                class="text-gray-400 hover:text-gray-700"
                title={gettext("Move down")}
              >
                <.icon name="hero-chevron-down" class="h-3 w-3" />
              </button>
            </div>
            <div :if={!@editable} class="w-12 shrink-0"></div>

            <%!-- readonly (not disabled) so values still submit on autosave of other fields --%>
            <input
              type="text"
              id={"dtl-contact-#{@section}-#{dtl.index}"}
              name={dtl[:contact_name].name}
              value={dtl[:contact_name].value}
              class={"w-56 border rounded px-2 py-1 #{if locked, do: "bg-gray-100 text-gray-600 cursor-not-allowed", else: ""}"}
              readonly={locked or !@editable}
              phx-hook={if line_editable, do: "tributeAutoComplete", else: nil}
              url={"/list/companies/#{@current_company.id}/#{@current_user.id}/autocomplete?schema=contact&name="}
            />

            <input
              :for={grade <- @grades}
              type="number"
              name={"#{dtl.name}[quantities][#{grade}]"}
              value={(dtl[:quantities].value || %{})[grade] || ""}
              class={"w-20 text-center border rounded px-1 py-1 #{if locked, do: "bg-gray-100 text-gray-600 cursor-not-allowed", else: ""}"}
              readonly={locked or !@editable}
            />

            <div class="w-20 text-center font-semibold py-1">
              {dtl_line_qty_total(dtl, @grades)}
            </div>

            <%!-- Existing documents: open only (no create) --%>
            <a
              :for={{doc_type, doc_id} <- issued_docs}
              href={doc_link_path(@current_company.id, doc_type, doc_id)}
              target="_blank"
              class="text-blue-600 hover:text-blue-800"
              title={gettext("Open %{type}", type: doc_type)}
            >
              <.icon name={doc_icon(doc_type)} class="h-4 w-4" />
            </a>

            <%!-- No documents yet: allow create --%>
            <a
              :if={
                @editable and !has_docs and @section == "planned_order" and
                  dtl[:contact_id].value not in [nil, ""]
              }
              href={egg_order_doc_url(@current_company.id, @date, dtl, @grades, "Invoice")}
              target="_blank"
              class="text-green-600 hover:text-green-800"
              title={gettext("Create Invoice")}
            >
              <.icon name="hero-document-plus" class="h-4 w-4" />
            </a>

            <a
              :if={
                @editable and !has_docs and @section == "planned_order" and
                  dtl[:contact_id].value not in [nil, ""]
              }
              href={egg_order_doc_url(@current_company.id, @date, dtl, @grades, "Receipt")}
              target="_blank"
              class="text-amber-600 hover:text-amber-800"
              title={gettext("Create Receipt")}
            >
              <.icon name="hero-banknotes" class="h-4 w-4" />
            </a>

            <a
              :if={
                @editable and !has_docs and @section == "planned_purchase" and
                  dtl[:contact_id].value not in [nil, ""]
              }
              href={egg_order_doc_url(@current_company.id, @date, dtl, @grades, "PurInvoice")}
              target="_blank"
              class="text-green-600 hover:text-green-800"
              title={gettext("Create Purchase Invoice")}
            >
              <.icon name="hero-document-plus" class="h-4 w-4" />
            </a>

            <a
              :if={
                @editable and !has_docs and @section == "planned_purchase" and
                  dtl[:contact_id].value not in [nil, ""]
              }
              href={egg_order_doc_url(@current_company.id, @date, dtl, @grades, "Payment")}
              target="_blank"
              class="text-amber-600 hover:text-amber-800"
              title={gettext("Create Payment")}
            >
              <.icon name="hero-banknotes" class="h-4 w-4" />
            </a>

            <span
              :if={@editable and locked}
              class="text-gray-400 cursor-not-allowed"
              title={gettext("Edit the linked document to change this line")}
            >
              <.icon name="hero-lock-closed" class="h-4 w-4" />
            </span>

            <button
              :if={line_editable}
              type="button"
              phx-click="delete_detail"
              phx-value-index={dtl.index}
              class="text-red-500 hover:text-red-700"
              title={gettext("Delete line")}
            >
              <.icon name="hero-trash" class="h-4 w-4" />
            </button>
          </div>
        </div>
      </.inputs_for>
    </div>
    """
  end

  defp egg_order_doc_url(company_id, date, dtl, grades, doc_type) do
    contact_name = dtl[:contact_name].value || ""
    contact_id = dtl[:contact_id].value || ""
    quantities = dtl[:quantities].value || %{}

    egg =
      grades
      |> Enum.reject(fn g ->
        qty = quantities[g]
        qty in [nil, "", "0", 0]
      end)
      |> Enum.map(fn g -> "#{URI.encode(g)}:#{quantities[g]}" end)
      |> Enum.join(",")

    "/companies/#{company_id}/#{doc_type}/new?" <>
      URI.encode_query(%{
        "contact_name" => contact_name,
        "contact_id" => contact_id,
        "date" => Date.to_iso8601(date),
        "egg" => egg
      })
  end

  defp section_totals(assigns) do
    sections =
      case assigns.section do
        "planned_order" -> EggStock.planned_sales_sections()
        "planned_purchase" -> EggStock.planned_purchase_sections()
        s -> [s]
      end

    assigns = assign(assigns, :sections, sections)

    ~H"""
    <div class="flex gap-1 mt-1 font-semibold text-sm text-gray-700 border-t pt-1">
      <div class="w-12 shrink-0"></div>
      <div class="w-56 text-right">{gettext("Total")}</div>
      <div :for={grade <- @grades} class="w-20 text-center">
        {Enum.reduce(@sections, 0, fn sec, acc -> acc + sum_quantities(@details || [], sec, grade) end)}
      </div>
      <div class="w-20 text-center">
        {Enum.reduce(@grades, 0, fn g, acc ->
          acc +
            Enum.reduce(@sections, 0, fn sec, a -> a + sum_quantities(@details || [], sec, g) end)
        end)}
      </div>
    </div>
    """
  end

  # --- Estimated Tab ---

  defp estimated_tab(assigns) do
    ~H"""
    <div class="flex flex-col items-center">
      <div class="w-fit max-w-full">
        <p class="text-xs text-gray-500 mb-3 max-w-xl">
          {gettext(
            "7-day forecast: production from recent history; sales/purchases from weekly books (or day overrides)."
          )}
        </p>

        <.forecast_table
          title={gettext("Est. Closing")}
          forecast={@forecast}
          grades={@grades}
          grade_labels={@grade_labels}
          value_key={:closing}
          row_hover="hover:bg-blue-100"
        />

        <.forecast_table
          title={gettext("Est. Daily Sales (weekly book)")}
          forecast={@forecast}
          grades={@grades}
          grade_labels={@grade_labels}
          value_key={:sales}
          row_hover="hover:bg-blue-100"
          class="mt-5"
        />

        <.forecast_table
          title={gettext("Est. Daily Purchases (weekly book)")}
          forecast={@forecast}
          grades={@grades}
          grade_labels={@grade_labels}
          value_key={:purchases}
          row_hover="hover:bg-emerald-100"
          class="mt-5"
        />
      </div>
    </div>
    """
  end

  defp forecast_table(assigns) do
    assigns = assign_new(assigns, :class, fn -> "" end)

    ~H"""
    <div class={@class}>
      <h3 class="font-semibold text-sm mb-1.5 text-gray-700">{@title}</h3>
      <div class="overflow-x-auto border rounded">
        <table class="text-sm border-collapse">
          <thead>
            <tr class="border-b bg-gray-50">
              <th class="text-left py-1.5 px-2 whitespace-nowrap font-semibold text-gray-600">
                {gettext("Date")}
              </th>
              <th class="text-left py-1.5 px-1.5 whitespace-nowrap font-semibold text-gray-600">
                {gettext("Day")}
              </th>
              <th
                :for={grade <- @grades}
                class="text-center py-1.5 px-1.5 min-w-[2.75rem] font-semibold text-gray-600"
              >
                {@grade_labels[grade]}
              </th>
              <th class="text-center py-1.5 px-1.5 min-w-[3rem] font-semibold text-gray-600">
                {gettext("Total")}
              </th>
            </tr>
          </thead>
          <tbody>
            <tr
              :for={row <- @forecast}
              class={"border-b last:border-0 cursor-pointer #{@row_hover}"}
              phx-click="goto_date"
              phx-value-date={Date.to_iso8601(row.date)}
            >
              <td class="py-1 px-2 font-medium whitespace-nowrap">
                {FullCircleWeb.Helpers.format_date(row.date)}
              </td>
              <td class="py-1 px-1.5 text-gray-500">
                {Calendar.strftime(row.date, "%a")}
              </td>
              <% values = Map.get(row, @value_key) || %{} %>
              <td
                :for={grade <- @grades}
                class={"text-center py-1 px-1.5 tabular-nums #{if @value_key == :closing and to_int(values[grade]) < 0, do: "text-red-600"}"}
              >
                {display_val(values[grade])}
              </td>
              <% total = Enum.reduce(@grades, 0, fn g, acc -> acc + to_int(values[g]) end) %>
              <td class={"text-center py-1 px-1.5 font-semibold tabular-nums #{if @value_key == :closing and total < 0, do: "text-red-600"}"}>
                {total}
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  # --- Settings Tab ---

  defp settings_tab(assigns) do
    ~H"""
    <div class="flex flex-col items-center">
      <div class="w-full max-w-lg space-y-4">
        <div class="border rounded p-3">
          <h3 class="font-semibold text-sm mb-3">{gettext("Estimation Settings")}</h3>

          <.form for={%{}} id="autosave-delay-form" phx-change="change_autosave_delay">
            <div class="flex items-center gap-3 mb-3">
              <label class="text-sm text-gray-600 w-44 shrink-0">
                {gettext("Autosave delay")}
              </label>
              <select name="autosave_delay" class="border rounded px-2 py-1 text-sm w-20">
                <option :for={s <- [1, 2, 3, 5, 10]} value={s} selected={s == @autosave_delay}>
                  {s}s
                </option>
              </select>
            </div>
          </.form>

          <.form for={%{}} id="lookback-days-form" phx-change="change_lookback_days">
            <div class="flex items-center gap-3">
              <label class="text-sm text-gray-600 w-44 shrink-0">
                {gettext("Production lookback")}
              </label>
              <select name="lookback_days" class="border rounded px-2 py-1 text-sm w-20">
                <option :for={d <- [2, 3, 4, 5, 6, 7]} value={d} selected={d == @lookback_days}>
                  {d} {gettext("days")}
                </option>
              </select>
            </div>
            <p class="text-xs text-gray-500 mt-1.5 pl-0 sm:pl-[11.75rem]">
              {gettext("Average production from recent days with a real closing balance.")}
            </p>
          </.form>
        </div>

        <div class="border rounded p-3">
          <h3 class="font-semibold text-sm mb-3">{gettext("Egg Grades")}</h3>

          <.form
            for={%{}}
            id="grades-form"
            autocomplete="off"
            phx-change="validate_grades"
            phx-submit="save_grades"
          >
            <div class="flex gap-1 mb-1.5 text-xs font-semibold text-gray-500">
              <div class="w-6">#</div>
              <div class="w-40">{gettext("Good Name")}</div>
              <div class="w-24">{gettext("Nickname")}</div>
            </div>

            <div :for={{grade, idx} <- Enum.with_index(@grades_params)} class="mb-1">
              <input type="hidden" name={"grades[#{idx}][id]"} value={grade["id"]} />
              <input type="hidden" name={"grades[#{idx}][delete]"} value={grade["delete"] || "false"} />
              <input
                :if={grade["delete"] == "true"}
                type="hidden"
                name={"grades[#{idx}][name]"}
                value={grade["name"]}
              />
              <input
                :if={grade["delete"] == "true"}
                type="hidden"
                name={"grades[#{idx}][nickname]"}
                value={grade["nickname"]}
              />

              <div :if={grade["delete"] != "true"} class="flex items-center gap-1">
                <span class="w-6 text-xs text-gray-400">{idx + 1}</span>

                <input
                  type="text"
                  id={"grade-name-#{idx}"}
                  name={"grades[#{idx}][name]"}
                  value={grade["name"]}
                  class="w-40 border rounded px-2 py-1 text-sm"
                  phx-hook="tributeAutoComplete"
                  url={"/list/companies/#{@current_company.id}/#{@current_user.id}/autocomplete?schema=good&name="}
                />

                <input
                  type="text"
                  name={"grades[#{idx}][nickname]"}
                  value={grade["nickname"]}
                  class="w-24 border rounded px-2 py-1 text-sm"
                />

                <div class="flex items-center shrink-0 ml-0.5">
                  <button
                    type="button"
                    phx-click="move_grade"
                    phx-value-index={idx}
                    phx-value-dir="up"
                    class="text-gray-400 hover:text-gray-700"
                    title={gettext("Move up")}
                  >
                    <.icon name="hero-chevron-up" class="h-3.5 w-3.5" />
                  </button>
                  <button
                    type="button"
                    phx-click="move_grade"
                    phx-value-index={idx}
                    phx-value-dir="down"
                    class="text-gray-400 hover:text-gray-700"
                    title={gettext("Move down")}
                  >
                    <.icon name="hero-chevron-down" class="h-3.5 w-3.5" />
                  </button>
                </div>
                <button
                  type="button"
                  phx-click="delete_grade"
                  phx-value-index={idx}
                  class="text-red-500 hover:text-red-700"
                  title={gettext("Delete")}
                >
                  <.icon name="hero-trash" class="h-4 w-4" />
                </button>
              </div>
            </div>

            <div class="flex items-center gap-3 mt-3">
              <button type="button" phx-click="add_grade" class="text-blue-600 hover:text-blue-800 text-sm">
                {gettext("Add grade")}
              </button>
              <button
                type="submit"
                class="px-3 py-1 bg-blue-600 hover:bg-blue-700 text-white rounded text-sm"
              >
                {gettext("Save grades")}
              </button>
            </div>
          </.form>
        </div>
      </div>
    </div>
    """
  end
end
