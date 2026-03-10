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

    weeks = Sys.get_setting(settings, "EggStock", "lookback-weeks") |> String.to_integer()
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
     |> assign(lookback_weeks: weeks)
     |> assign(lookback_days: days)
     |> assign(autosave_delay: autosave_delay)
     |> assign(save_status: nil)
     |> assign(show_ignored: true)
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
    lookback_weeks = socket.assigns.lookback_weeks
    lookback_days = socket.assigns.lookback_days

    case EggStock.get_or_create_day(company.id, date) do
      {:ok, day} ->
        if is_future do
          load_future_day(socket, day, company, date, lookback_weeks, lookback_days)
        else
          load_today_or_past_day(socket, day, company, date, lookback_weeks, lookback_days)
        end

      {:error, _cs} ->
        socket |> put_flash(:error, gettext("Failed to load day data"))
    end
  end

  defp load_tab_data(socket, "estimated") do
    company = socket.assigns.current_company
    date = socket.assigns.date
    lookback_weeks = socket.assigns.lookback_weeks
    lookback_days = socket.assigns.lookback_days

    forecast =
      EggStock.compute_7day_forecast(company.id, date, lookback_weeks, lookback_days)

    assign(socket, forecast: forecast)
  end

  defp load_tab_data(socket, "settings") do
    company = socket.assigns.current_company
    grades = EggStock.list_grades(company.id)
    assign(socket, grades: grades, grades_params: grades_to_params(grades))
  end

  defp load_tab_data(socket, _), do: socket

  defp load_future_day(socket, day, company, date, lookback_weeks, lookback_days) do
    est_opening =
      EggStock.compute_estimated_opening(
        company.id,
        date,
        lookback_weeks,
        lookback_days
      )

    est_production = EggStock.compute_avg_production(company.id, lookback_days)
    est_harvest = EggStock.compute_avg_harvest(company.id, lookback_days)

    day = %{day | opening_bal: est_opening}
    day = prepopulate_orders(day, company.id, date, lookback_weeks, [], [])

    est_closing =
      compute_est_closing(
        est_opening,
        est_production,
        day.egg_stock_day_details,
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

  defp load_today_or_past_day(socket, day, company, date, lookback_weeks, lookback_days) do
    opening = EggStock.get_previous_closing_bal(company.id, date)
    day = %{day | opening_bal: opening}

    actual_sales = EggStock.actual_sales_for_date(company.id, date)
    actual_purchases = EggStock.actual_purchases_for_date(company.id, date)
    harvested = EggStock.harvest_total_for_date(company.id, date)

    est_harvest =
      if harvested == 0,
        do: EggStock.compute_avg_harvest(company.id, lookback_days),
        else: nil

    yesterday_ug = EggStock.get_previous_ungraded_bal(company.id, date)

    day =
      if socket.assigns.editable do
        prepopulate_orders(day, company.id, date, lookback_weeks, actual_sales, actual_purchases)
      else
        day
      end

    # For today, compute est_closing and est_production
    {est_production, est_closing} =
      if socket.assigns.editable do
        prod = EggStock.compute_avg_production(company.id, lookback_days)

        closing =
          compute_est_closing(
            opening,
            prod,
            day.egg_stock_day_details,
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

  defp assign_day_form(socket, day) do
    details =
      Enum.filter(day.egg_stock_day_details, &(&1.section in ["actual_order", "actual_purchase"]))

    scoped_day = %{day | egg_stock_day_details: []}

    cs =
      EggStockDay.changeset(scoped_day, %{})
      |> Ecto.Changeset.put_assoc(:egg_stock_day_details, details)

    assign(socket, form: to_form(cs))
  end

  defp prepopulate_orders(day, company_id, date, lookback_weeks, actual_sales, actual_purchases) do
    has_orders = Enum.any?(day.egg_stock_day_details, &(&1.section == "actual_order"))
    has_purchases = Enum.any?(day.egg_stock_day_details, &(&1.section == "actual_purchase"))

    if has_orders or has_purchases do
      day
    else
      dow = Date.day_of_week(date)
      sales_avgs = EggStock.sales_averages_by_dow(company_id, lookback_weeks)
      purchase_avgs = EggStock.purchase_averages_by_dow(company_id, lookback_weeks)

      sales_rows = sales_avgs[dow] || []
      purchase_rows = purchase_avgs[dow] || []

      sold_contact_ids = MapSet.new(actual_sales, & &1.contact_id)
      bought_contact_ids = MapSet.new(actual_purchases, & &1.contact_id)

      order_details =
        if sales_rows != [] do
          templates_to_details(sales_rows, "actual_order", sold_contact_ids)
        else
          actuals_to_details(actual_sales, "actual_order")
        end
        |> Enum.sort_by(& &1.contact_name)

      purchase_details =
        if purchase_rows != [] do
          templates_to_details(purchase_rows, "actual_purchase", bought_contact_ids)
        else
          actuals_to_details(actual_purchases, "actual_purchase")
        end
        |> Enum.sort_by(& &1.contact_name)

      %{
        day
        | egg_stock_day_details: day.egg_stock_day_details ++ order_details ++ purchase_details
      }
    end
  end

  defp templates_to_details(template_rows, section, exclude_contact_ids) do
    template_rows
    |> Enum.reject(fn row -> MapSet.member?(exclude_contact_ids, row.contact_id) end)
    |> Enum.map(fn row ->
      %EggStockDayDetail{
        section: section,
        contact_id: row.contact_id,
        contact_name: row.contact_name,
        quantities: row.quantities || %{}
      }
    end)
  end

  defp actuals_to_details(actual_rows, section) do
    Enum.map(actual_rows, fn row ->
      %EggStockDayDetail{
        section: section,
        contact_id: row.contact_id,
        contact_name: row.contact_name,
        quantities: row.quantities || %{}
      }
    end)
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

  defp compute_est_closing(opening, est_production, details, grades) do
    sales_total =
      details
      |> Enum.filter(&(&1.section == "actual_order" and !&1.ignore))
      |> Enum.reduce(Map.new(grades, &{&1, 0}), fn d, acc ->
        Map.merge(acc, d.quantities || %{}, fn _k, v1, v2 -> to_int(v1) + to_int(v2) end)
      end)

    purchase_total =
      details
      |> Enum.filter(&(&1.section == "actual_purchase" and !&1.ignore))
      |> Enum.reduce(Map.new(grades, &{&1, 0}), fn d, acc ->
        Map.merge(acc, d.quantities || %{}, fn _k, v1, v2 -> to_int(v1) + to_int(v2) end)
      end)

    Map.new(grades, fn g ->
      o = to_int(opening[g])
      p = to_int(est_production[g])
      s = to_int(sales_total[g])
      b = to_int(purchase_total[g])
      {g, o + p + b - s}
    end)
  end

  defp compute_est_closing_from_params(opening, est_production, params, grades) do
    details = params["egg_stock_day_details"] || %{}

    {sales_total, purchase_total} =
      Enum.reduce(details, {Map.new(grades, &{&1, 0}), Map.new(grades, &{&1, 0})}, fn {_k, detail},
                                                                                      {sales,
                                                                                       purchases} ->
        if detail["ignore"] == "true" do
          {sales, purchases}
        else
          quantities = detail["quantities"] || %{}

          case detail["section"] do
            "actual_order" ->
              {Map.merge(sales, quantities, fn _k, v1, v2 -> to_int(v1) + to_int(v2) end),
               purchases}

            "actual_purchase" ->
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

  # --- Events ---

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    socket = flush_autosave(socket)

    {:noreply,
     socket
     |> assign(active_tab: tab)
     |> load_tab_data(tab)}
  end

  def handle_event("toggle_show_ignored", _, socket) do
    {:noreply, assign(socket, show_ignored: !socket.assigns.show_ignored)}
  end

  def handle_event("nav_date", %{"dir" => dir}, socket) do
    socket = flush_autosave(socket)
    date = socket.assigns.date
    new_date = if dir == "prev", do: Date.add(date, -1), else: Date.add(date, 1)

    {:noreply,
     push_patch(socket,
       to: ~p"/companies/#{socket.assigns.current_company.id}/egg_stock/#{Date.to_iso8601(new_date)}"
     )}
  end

  def handle_event("goto_date", %{"date" => date_str}, socket) do
    socket = flush_autosave(socket)

    {:noreply,
     socket
     |> assign(active_tab: "now")
     |> push_patch(
       to: ~p"/companies/#{socket.assigns.current_company.id}/egg_stock/#{date_str}"
     )}
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

  def handle_event("add_detail", %{"section" => section}, socket) do
    cs = socket.assigns.form.source
    existing = Ecto.Changeset.get_assoc(cs, :egg_stock_day_details)

    new_detail = %EggStockDayDetail{
      section: section,
      quantities: %{},
      _persistent_id: Enum.count(existing)
    }

    cs =
      cs
      |> Ecto.Changeset.put_assoc(:egg_stock_day_details, existing ++ [new_detail])
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(cs))}
  end

  def handle_event("toggle_ignore", %{"index" => index}, socket) do
    index = String.to_integer(index)
    cs = socket.assigns.form.source

    details =
      Ecto.Changeset.get_assoc(cs, :egg_stock_day_details)
      |> Enum.with_index()
      |> Enum.map(fn {detail_cs, i} ->
        if i == index do
          current = Ecto.Changeset.get_field(detail_cs, :ignore) || false
          Ecto.Changeset.put_change(detail_cs, :ignore, !current)
        else
          detail_cs
        end
      end)

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

    socket = schedule_autosave(socket, params)

    {:noreply, socket}
  end

  # --- Settings events ---

  def handle_event("change_lookback", %{"lookback_weeks" => weeks_str}, socket) do
    weeks = String.to_integer(weeks_str)
    setting = Enum.find(socket.assigns.settings, &(&1.code == "lookback-weeks"))
    Sys.update_setting(setting, weeks_str)

    {:noreply,
     socket
     |> assign(lookback_weeks: weeks)}
  end

  def handle_event("change_lookback_days", %{"lookback_days" => days_str}, socket) do
    days = String.to_integer(days_str)
    setting = Enum.find(socket.assigns.settings, &(&1.code == "lookback-days"))
    Sys.update_setting(setting, days_str)

    {:noreply,
     socket
     |> assign(lookback_days: days)}
  end

  def handle_event("change_autosave_delay", %{"autosave_delay" => delay_str}, socket) do
    delay = String.to_integer(delay_str)
    setting = Enum.find(socket.assigns.settings, &(&1.code == "autosave-delay"))
    if setting, do: Sys.update_setting(setting, delay_str)

    {:noreply,
     socket
     |> assign(autosave_delay: delay)}
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
           "ignore" => to_string(Ecto.Changeset.get_field(d, :ignore) || false),
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

  # --- Autosave ---

  @impl true
  def handle_info({:autosave, params}, socket) do
    socket = assign(socket, save_status: :saving)
    do_save(params, socket)
  end

  def handle_info(:clear_save_status, socket) do
    {:noreply, assign(socket, save_status: nil)}
  end

  defp schedule_autosave(socket, params) do
    if timer = socket.assigns[:autosave_timer], do: Process.cancel_timer(timer)
    delay = socket.assigns.autosave_delay * 1_000
    timer = Process.send_after(self(), {:autosave, params}, delay)
    assign(socket, autosave_timer: timer, autosave_params: params)
  end

  defp flush_autosave(socket) do
    if timer = socket.assigns[:autosave_timer] do
      Process.cancel_timer(timer)
      params = socket.assigns[:autosave_params]
      {:noreply, socket} = do_save(params, socket)
      assign(socket, autosave_timer: nil, autosave_params: nil)
    else
      socket
    end
  end

  defp do_save(params, socket) do
    day = socket.assigns.day

    all_other_details =
      day.egg_stock_day_details
      |> Enum.filter(fn d ->
        d.section not in ["actual_order", "actual_purchase"]
      end)
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
        {:noreply, assign(socket, save_status: :error)
         |> put_flash(:error, gettext("You are not authorised to perform this action"))}
    end
  end

  # --- Helpers ---

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

  defp validate_day(params, socket) do
    day = socket.assigns.day

    scoped_details =
      Enum.filter(
        day.egg_stock_day_details,
        &(&1.id && &1.section in ["actual_order", "actual_purchase"])
      )

    scoped_day = %{day | egg_stock_day_details: scoped_details}

    cs =
      EggStockDay.changeset(scoped_day, params)
      |> Map.put(:action, :validate)

    socket = assign(socket, form: to_form(cs))

    # Recompute est_closing from form params
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

    socket = schedule_autosave(socket, params)

    {:noreply, socket}
  end

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
    |> Enum.filter(&(&1.section == section and !&1.ignore))
    |> Enum.reduce(0, fn d, acc ->
      acc + to_int((d.quantities || %{})[grade])
    end)
  end

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
    <div class="mx-auto w-8/12 mb-10">
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
        <span class="text-lg font-semibold px-2">
          {FullCircleWeb.Helpers.format_date(@date)}
        </span>
        <button
          type="button"
          phx-click="nav_date"
          phx-value-dir="next"
          class="px-2 py-1 text-lg font-bold text-gray-600 hover:text-blue-600"
        >
          <.icon name="hero-chevron-right" class="h-5 w-5" />
        </button>
        <button
          type="button"
          phx-click="goto_date"
          phx-value-date={Date.to_iso8601(Date.utc_today())}
          class="px-2 py-1 text-sm text-blue-600 hover:text-blue-800 border border-blue-300 rounded"
        >
          {gettext("Today")}
        </button>
        <.save_status status={@save_status} />
      </div>

      <%!-- Tabs --%>
      <div class="flex gap-1 mb-4 border-b border-gray-300">
        <.tab_button tab="now" active={@active_tab} label={gettext("Stock")} />
        <.tab_button tab="estimated" active={@active_tab} label={gettext("Estimated")} />
        <.tab_button tab="settings" active={@active_tab} label={gettext("Settings")} />
      </div>

      <%!-- Tab content --%>
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
          show_ignored={@show_ignored}
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
          lookback_weeks={@lookback_weeks}
          lookback_days={@lookback_days}
          autosave_delay={@autosave_delay}
          show_ignored={@show_ignored}
          current_company={@current_company}
          current_user={@current_user}
        />
      </div>
    </div>
    """
  end

  # --- Components ---

  defp tab_button(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="switch_tab"
      phx-value-tab={@tab}
      class={"px-4 py-2 text-sm font-medium #{if @tab == @active, do: "border-b-2 border-blue-500 text-blue-600", else: "text-gray-500 hover:text-gray-700"}"}
    >
      {@label}
    </button>
    """
  end

  # --- Now Tab ---

  defp now_tab(assigns) do
    ~H"""
    <%!-- Grade column headers --%>
    <div class="flex gap-1 mb-1">
      <div class="w-40"></div>
      <div :for={grade <- @grades} class="w-20 text-center text-sm font-semibold text-gray-600">
        {@grade_labels[grade]}
      </div>
      <div class="w-20 text-center text-sm font-semibold text-gray-600">{gettext("Total")}</div>
    </div>

    <%!-- Past date (read-only) --%>
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
      >
        <%!-- Expired --%>
        <div class="flex gap-1 mb-1">
          <div class="w-40 font-bold text-sm py-1">{gettext("Expired")}</div>
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

        <%!-- Closing Balance --%>
        <div class="flex gap-1 mb-1">
          <div class="w-40 font-bold text-sm py-1">{gettext("Closing")}</div>
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

        <%!-- Production = sold + expired + closing - opening - purchased --%>
        <% productions =
          Map.new(@grades, fn g ->
            o = to_int((@day.opening_bal || %{})[g])
            c = to_int((@form[:closing_bal].value || %{})[g])
            b = actual_total(@actual_purchases, g)
            s = actual_total(@actual_sales, g)
            e = to_int((@form[:expired].value || %{})[g])
            {g, s + e + c - o - b}
          end) %>
        <.summary_row
          label={gettext("Production")}
          grades={@grades}
          values={productions}
          bg="bg-green-50"
        />

        <%!-- Harvested / Yesterday UG / UG --%>
        <div class="flex gap-1 mb-1">
          <div class="w-40 font-bold text-sm py-1">{gettext("Harvest/UG/Loss")}</div>
          <div class="w-20 text-center border rounded px-2 py-1 bg-amber-50">{@harvested}</div>
          <div class="w-20 text-center border rounded px-2 py-1 bg-gray-100">{@yesterday_ug}</div>
          <input
            type="number"
            name="egg_stock_day[ungraded_bal]"
            value={@form[:ungraded_bal].value || 0}
            class="w-20 text-center border rounded px-1 py-1"
            phx-debounce="blur"
          />
          <%!-- Loss --%>
          <% closing_total =
            Enum.reduce(@grades, 0, fn g, acc ->
              acc + to_int((@form[:closing_bal].value || %{})[g])
            end) %>
          <% has_closing = closing_total > 0 %>
          <div :if={has_closing} class="flex gap-1 mb-1">
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
              @harvested + opening_total + purchased_total + @yesterday_ug - ug_today - sold_total -
                closing_total - expired_total %>
            <div class={"w-20 text-center border rounded px-2 py-1 #{if loss < 0, do: "bg-red-100 text-red-700", else: "bg-orange-50"}"}>
              {loss}
            </div>
          </div>
        </div>
        <div class="flex gap-1 mb-2 text-xs text-gray-500">
          <div class="w-40"></div>
          <div class="w-20 text-center">{gettext("Harvested")}</div>
          <div class="w-20 text-center">{gettext("Ytd UG")}</div>
          <div class="w-20 text-center">{gettext("UG")}</div>
          <div class="w-20 text-center">{gettext("Loss")}</div>
        </div>

        <%!-- Yield per grade --%>
        <% harvest_plus_ug = @harvested + @yesterday_ug %>
        <% yields =
          Map.new(@grades, fn g ->
            p = to_int(productions[g])
            {g, if(harvest_plus_ug > 0, do: Float.round(p / harvest_plus_ug * 100, 2), else: 0.0)}
          end) %>
        <.summary_row
          label={gettext("Yield %")}
          grades={@grades}
          values={yields}
          bg="bg-yellow-50"
          suffix="%"
        />

        <%!-- Note --%>
        <div class="mb-4 mt-2">
          <label class="font-bold">{gettext("Note")}</label>
          <textarea
            name="egg_stock_day[note]"
            class="w-full border rounded p-2"
            rows="2"
          >{@form[:note].value}</textarea>
        </div>
      </.form>

      <%!-- Print button for past dates with closing balance --%>
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

    <%!-- Today (editable, not future) --%>
    <div :if={@editable and !@is_future}>
      <.summary_row
        label={gettext("Opening")}
        grades={@grades}
        values={@day.opening_bal || %{}}
        bg="bg-gray-100"
      />

      <.form for={@form} id="day-form" autocomplete="off" phx-change="validate" phx-submit="save">
        <%!-- Purchase Orders Section --%>
        <div class="mb-2">
          <div class="flex items-center gap-1 mb-1">
            <h3 class="font-bold text-sm">{gettext("Purchase Orders")}</h3>
            <button
              type="button"
              phx-click="add_detail"
              phx-value-section="actual_purchase"
              class="text-blue-600 hover:text-blue-800"
            >
              <.icon name="hero-plus-circle" class="h-5 w-5" />
            </button>
          </div>
          <.detail_lines
            form={@form}
            section="actual_purchase"
            grades={@grades}
            grade_labels={@grade_labels}
            editable={@editable}
            current_company={@current_company}
            current_user={@current_user}
            date={@date}
            show_ignored={@show_ignored}
          />
          <.section_totals
            details={@day.egg_stock_day_details}
            section="actual_purchase"
            grades={@grades}
          />
        </div>

        <%!-- Sales Order Section --%>
        <div class="mb-2">
          <div class="flex items-center gap-1 mb-1">
            <h3 class="font-bold text-sm">{gettext("Sales Orders")}</h3>
            <button
              type="button"
              phx-click="add_detail"
              phx-value-section="actual_order"
              class="text-blue-600 hover:text-blue-800"
            >
              <.icon name="hero-plus-circle" class="h-5 w-5" />
            </button>
          </div>
          <.detail_lines
            form={@form}
            section="actual_order"
            grades={@grades}
            grade_labels={@grade_labels}
            editable={@editable}
            current_company={@current_company}
            current_user={@current_user}
            date={@date}
            show_ignored={@show_ignored}
          />
          <.section_totals
            details={@day.egg_stock_day_details}
            section="actual_order"
            grades={@grades}
          />
        </div>

        <%!-- Actual Purchases --%>
        <.actual_data_section
          title={gettext("Purchases")}
          rows={@actual_purchases}
          grades={@grades}
          bg_class="bg-emerald-50"
          title_class="text-emerald-700"
          company_id={@current_company.id}
        />

        <%!-- Actual Sales --%>
        <.actual_data_section
          title={gettext("Sales")}
          rows={@actual_sales}
          grades={@grades}
          bg_class="bg-blue-50"
          title_class="text-blue-700"
          company_id={@current_company.id}
        />

        <%!-- Est Production --%>
        <.summary_row
          :if={@est_production}
          label={gettext("Est Production")}
          grades={@grades}
          values={@est_production}
          bg="bg-green-50"
        />

        <%!-- Est Closing --%>
        <.summary_row
          :if={@est_closing}
          label={gettext("Est Closing")}
          grades={@grades}
          values={@est_closing}
          bg="bg-purple-50"
        />

        <%!-- Expired --%>
        <div class="flex gap-1 mb-1">
          <div class="w-40 font-bold text-sm py-1">{gettext("Expired")}</div>
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

        <%!-- Closing Balance --%>
        <div class="flex gap-1 mb-1">
          <div class="w-40 font-bold text-sm py-1">{gettext("Closing")}</div>
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

        <%!-- Production = sold + expired + closing - opening - purchased --%>
        <% productions_ed =
          Map.new(@grades, fn g ->
            o = to_int((@day.opening_bal || %{})[g])
            c = to_int((@form[:closing_bal].value || %{})[g])
            b = actual_total(@actual_purchases, g)
            s = actual_total(@actual_sales, g)
            e = to_int((@form[:expired].value || %{})[g])
            {g, s + e + c - o - b}
          end) %>
        <.summary_row
          label={gettext("Production")}
          grades={@grades}
          values={productions_ed}
          bg="bg-green-50"
        />

        <%!-- Harvested / Yesterday UG / UG --%>
        <% harvest_display = if @harvested == 0 && @est_harvest, do: @est_harvest, else: @harvested %>
        <div class="flex gap-1 mb-1">
          <div class="w-40 font-bold text-sm py-1">{gettext("Harvest/UG")}</div>
          <div class={"w-20 text-center border rounded px-2 py-1 #{if @harvested == 0 && @est_harvest, do: "bg-purple-50", else: "bg-amber-50"}"}>
            {harvest_display}
          </div>
          <div class="w-20 text-center border rounded px-2 py-1 bg-gray-100">{@yesterday_ug}</div>
          <input
            type="number"
            name="egg_stock_day[ungraded_bal]"
            value={@form[:ungraded_bal].value || 0}
            class="w-20 text-center border rounded px-1 py-1"
            phx-debounce="blur"
          />
          <%!-- Loss --%>
          <% closing_total_ed =
            Enum.reduce(@grades, 0, fn g, acc ->
              acc + to_int((@form[:closing_bal].value || %{})[g])
            end) %>
          <% has_closing_ed = closing_total_ed > 0 %>
          <div :if={has_closing_ed} class="flex gap-1 mb-1">
            <% opening_total_ed =
              Enum.reduce(@grades, 0, fn g, acc -> acc + to_int((@day.opening_bal || %{})[g]) end) %>
            <% sold_total_ed =
              Enum.reduce(@grades, 0, fn g, acc -> acc + actual_total(@actual_sales, g) end) %>
            <% purchased_total_ed =
              Enum.reduce(@grades, 0, fn g, acc -> acc + actual_total(@actual_purchases, g) end) %>
            <% expired_total_ed =
              Enum.reduce(@grades, 0, fn g, acc -> acc + to_int((@form[:expired].value || %{})[g]) end) %>
            <% ug_today_ed = to_int(@form[:ungraded_bal].value) %>
            <% loss_ed =
              harvest_display + opening_total_ed + purchased_total_ed + @yesterday_ug - ug_today_ed -
                sold_total_ed - closing_total_ed - expired_total_ed %>
            <div class={"w-20 text-center font-semibold border rounded px-2 py-1 #{if loss_ed < 0, do: "bg-red-100 text-red-700", else: "bg-orange-50"}"}>
              {loss_ed}
            </div>
          </div>
        </div>
        <div class="flex gap-1 mb-2 text-xs text-gray-500">
          <div class="w-40"></div>
          <div class="w-20 text-center">
            {if @harvested == 0 && @est_harvest,
              do: gettext("Est Harvest"),
              else: gettext("Harvested")}
          </div>
          <div class="w-20 text-center">{gettext("Ytd UG")}</div>
          <div class="w-20 text-center">{gettext("UG")}</div>
        </div>

        <%!-- Yield per grade --%>
        <% harvest_plus_ug_editable = harvest_display + @yesterday_ug %>
        <% yields_ed =
          Map.new(@grades, fn g ->
            p = to_int(productions_ed[g])

            {g,
             if(harvest_plus_ug_editable > 0,
               do: Float.round(p / harvest_plus_ug_editable * 100, 2),
               else: 0.0
             )}
          end) %>
        <.summary_row
          label={gettext("Yield %")}
          grades={@grades}
          values={yields_ed}
          bg="bg-yellow-50"
          suffix="%"
        />

        <%!-- Note --%>
        <div class="mb-4 mt-2">
          <label class="font-bold">{gettext("Note")}</label>
          <textarea
            name="egg_stock_day[note]"
            class="w-full border rounded p-2"
            rows="2"
          >{@form[:note].value}</textarea>
        </div>
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

    <%!-- Future date --%>
    <div :if={@is_future}>
      <%!-- Est Opening --%>
      <.summary_row
        label={gettext("Est Opening")}
        grades={@grades}
        values={@est_opening || %{}}
        bg="bg-gray-100"
      />

      <.form
        for={@form}
        id="day-form-future"
        autocomplete="off"
        phx-change="validate"
        phx-submit="save"
      >
        <%!-- Purchase Orders Section --%>
        <div class="mb-2">
          <div class="flex items-center gap-1 mb-1">
            <h3 class="font-bold text-sm">{gettext("Purchase Orders")}</h3>
            <button
              type="button"
              phx-click="add_detail"
              phx-value-section="actual_purchase"
              class="text-blue-600 hover:text-blue-800"
            >
              <.icon name="hero-plus-circle" class="h-5 w-5" />
            </button>
          </div>
          <.detail_lines
            form={@form}
            section="actual_purchase"
            grades={@grades}
            grade_labels={@grade_labels}
            editable={true}
            current_company={@current_company}
            current_user={@current_user}
            date={@date}
            show_ignored={@show_ignored}
          />
          <.section_totals
            details={@day.egg_stock_day_details}
            section="actual_purchase"
            grades={@grades}
          />
        </div>

        <%!-- Sales Order Section --%>
        <div class="mb-2">
          <div class="flex items-center gap-1 mb-1">
            <h3 class="font-bold text-sm">{gettext("Sales Orders")}</h3>
            <button
              type="button"
              phx-click="add_detail"
              phx-value-section="actual_order"
              class="text-blue-600 hover:text-blue-800"
            >
              <.icon name="hero-plus-circle" class="h-5 w-5" />
            </button>
          </div>
          <.detail_lines
            form={@form}
            section="actual_order"
            grades={@grades}
            grade_labels={@grade_labels}
            editable={true}
            current_company={@current_company}
            current_user={@current_user}
            date={@date}
            show_ignored={@show_ignored}
          />
          <.section_totals
            details={@day.egg_stock_day_details}
            section="actual_purchase"
            grades={@grades}
          />
        </div>

        <%!-- Est Production --%>
        <.summary_row
          label={gettext("Est Production")}
          grades={@grades}
          values={@est_production || %{}}
          bg="bg-green-50"
        />

        <%!-- Est Harvest --%>
        <div class="flex gap-1 mb-1">
          <div class="w-40 font-bold text-sm py-1">{gettext("Est Harvest")}</div>
          <div class="w-20 text-center border rounded px-2 py-1 bg-amber-50">{@est_harvest}</div>
        </div>

        <%!-- Est Closing --%>
        <.summary_row
          label={gettext("Est Closing")}
          grades={@grades}
          values={@est_closing || %{}}
          bg="bg-purple-50"
        />

        <%!-- Note --%>
        <div class="mb-4 mt-2">
          <label class="font-bold">{gettext("Note")}</label>
          <textarea
            name="egg_stock_day[note]"
            class="w-full border rounded p-2"
            rows="2"
          >{@form[:note].value}</textarea>
        </div>
      </.form>
    </div>
    """
  end

  defp summary_row(assigns) do
    assigns = assign_new(assigns, :suffix, fn -> "" end)

    ~H"""
    <div class="flex gap-1 mb-1">
      <div class="w-40 font-bold text-sm py-1">{@label}</div>
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
        <span class="w-40 truncate flex items-center gap-1" title={row.contact_name}>
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
        <div class="w-40 text-right">{gettext("Total")}</div>
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
        <% ignored = dtl[:ignore].value in [true, "true"] %>
        <div
          :if={dtl[:section].value == @section and (@show_ignored or !ignored)}
          class={"flex items-center gap-1 #{if ignored, do: "opacity-40"}"}
        >
          <input :if={dtl[:id].value} type="hidden" name={dtl[:id].name} value={dtl[:id].value} />
          <input type="hidden" name={dtl[:section].name} value={@section} />
          <input type="hidden" name={dtl[:contact_id].name} value={dtl[:contact_id].value} />
          <input type="hidden" name={dtl[:ignore].name} value={"#{dtl[:ignore].value}"} />
          <input type="hidden" name={dtl[:_persistent_id].name} value={dtl.index} />

          <input
            type="text"
            id={"dtl-contact-#{@section}-#{dtl.index}"}
            name={dtl[:contact_name].name}
            value={dtl[:contact_name].value}
            class="w-40 border rounded px-2 py-1"
            disabled={!@editable}
            phx-hook="tributeAutoComplete"
            url={"/list/companies/#{@current_company.id}/#{@current_user.id}/autocomplete?schema=contact&name="}
          />

          <input
            :for={grade <- @grades}
            type="number"
            name={"#{dtl.name}[quantities][#{grade}]"}
            value={(dtl[:quantities].value || %{})[grade] || ""}
            class="w-20 text-center border rounded px-1 py-1"
            disabled={!@editable}
          />

          <div class="w-20 text-center font-semibold py-1">
            {Enum.reduce(@grades, 0, fn g, acc -> acc + to_int((dtl[:quantities].value || %{})[g]) end)}
          </div>

          <button
            :if={@editable}
            type="button"
            phx-click="toggle_ignore"
            phx-value-index={dtl.index}
            class={if ignored, do: "text-green-500 hover:text-green-700", else: "text-red-500 hover:text-red-700"}
            title={if ignored, do: gettext("Enable"), else: gettext("Ignore")}
          >
            <.icon name={if ignored, do: "hero-eye", else: "hero-eye-slash"} class="h-4 w-4" />
          </button>

          <a
            :if={@editable and @section == "actual_order" and dtl[:contact_id].value not in [nil, ""]}
            href={egg_order_doc_url(@current_company.id, @date, dtl, @grades, "Invoice")}
            target="_blank"
            class="text-green-600 hover:text-green-800"
            title={gettext("Create Invoice")}
          >
            <.icon name="hero-document-plus" class="h-4 w-4" />
          </a>

          <a
            :if={@editable and @section == "actual_order" and dtl[:contact_id].value not in [nil, ""]}
            href={egg_order_doc_url(@current_company.id, @date, dtl, @grades, "Receipt")}
            target="_blank"
            class="text-amber-600 hover:text-amber-800"
            title={gettext("Create Receipt")}
          >
            <.icon name="hero-banknotes" class="h-4 w-4" />
          </a>
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
    ~H"""
    <div class="flex gap-1 mt-1 font-semibold text-sm text-gray-700 border-t pt-1">
      <div class="w-40 text-right">{gettext("Total")}</div>
      <div :for={grade <- @grades} class="w-20 text-center">
        {sum_quantities(@details, @section, grade)}
      </div>
      <div class="w-20 text-center">
        {Enum.reduce(@grades, 0, fn g, acc -> acc + sum_quantities(@details, @section, g) end)}
      </div>
    </div>
    """
  end

  # --- Estimated Tab ---

  defp estimated_tab(assigns) do
    ~H"""
    <div class="overflow-x-auto">
      <table class="w-full text-sm">
        <thead>
          <tr class="border-b">
            <th class="text-left py-2 px-2 w-28">{gettext("Date")}</th>
            <th class="text-left py-2 px-1 w-16">{gettext("Day")}</th>
            <th :for={grade <- @grades} class="text-center py-2 px-1 w-20">
              {@grade_labels[grade]}
            </th>
            <th class="text-center py-2 px-1 w-20">{gettext("Total")}</th>
          </tr>
        </thead>
        <tbody>
          <tr
            :for={row <- @forecast}
            class="border-b hover:bg-blue-100 cursor-pointer"
            phx-click="goto_date"
            phx-value-date={Date.to_iso8601(row.date)}
          >
            <td class="py-1 px-2 font-medium">
              {FullCircleWeb.Helpers.format_date(row.date)}
            </td>
            <td class="py-1 px-1 text-gray-500">
              {Calendar.strftime(row.date, "%a")}
            </td>
            <td
              :for={grade <- @grades}
              class={"text-center py-1 px-1 #{if to_int(row.closing[grade]) < 0, do: "text-red-600"}"}
            >
              {display_val(row.closing[grade])}
            </td>
            <% total = Enum.reduce(@grades, 0, fn g, acc -> acc + to_int(row.closing[g]) end) %>
            <td class={"text-center py-1 px-1 font-semibold #{if total < 0, do: "text-red-600"}"}>
              {total}
            </td>
          </tr>
        </tbody>
      </table>

      <%!-- Sales/Purchases breakdown --%>
      <div class="mt-6">
        <h3 class="font-bold text-sm mb-2">{gettext("Est. Daily Sales")}</h3>
        <table class="w-full text-sm">
          <thead>
            <tr class="border-b">
              <th class="text-left py-2 px-2 w-28">{gettext("Date")}</th>
              <th class="text-left py-2 px-1 w-16">{gettext("Day")}</th>
              <th :for={grade <- @grades} class="text-center py-2 px-1 w-20">
                {@grade_labels[grade]}
              </th>
              <th class="text-center py-2 px-1 w-20">{gettext("Total")}</th>
            </tr>
          </thead>
          <tbody>
            <tr
              :for={row <- @forecast}
              class="border-b hover:bg-blue-100 cursor-pointer"
              phx-click="goto_date"
              phx-value-date={Date.to_iso8601(row.date)}
            >
              <td class="py-1 px-2 font-medium">
                {FullCircleWeb.Helpers.format_date(row.date)}
              </td>
              <td class="py-1 px-1 text-gray-500">
                {Calendar.strftime(row.date, "%a")}
              </td>
              <td :for={grade <- @grades} class="text-center py-1 px-1">
                {display_val(row.sales[grade])}
              </td>
              <td class="text-center py-1 px-1 font-semibold">
                {Enum.reduce(@grades, 0, fn g, acc -> acc + to_int(row.sales[g]) end)}
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <div class="mt-4">
        <h3 class="font-bold text-sm mb-2">{gettext("Est. Daily Purchases")}</h3>
        <table class="w-full text-sm">
          <thead>
            <tr class="border-b">
              <th class="text-left py-2 px-2 w-28">{gettext("Date")}</th>
              <th class="text-left py-2 px-1 w-16">{gettext("Day")}</th>
              <th :for={grade <- @grades} class="text-center py-2 px-1 w-20">
                {@grade_labels[grade]}
              </th>
              <th class="text-center py-2 px-1 w-20">{gettext("Total")}</th>
            </tr>
          </thead>
          <tbody>
            <tr
              :for={row <- @forecast}
              class="border-b hover:bg-emerald-100 cursor-pointer"
              phx-click="goto_date"
              phx-value-date={Date.to_iso8601(row.date)}
            >
              <td class="py-1 px-2 font-medium">
                {FullCircleWeb.Helpers.format_date(row.date)}
              </td>
              <td class="py-1 px-1 text-gray-500">
                {Calendar.strftime(row.date, "%a")}
              </td>
              <td :for={grade <- @grades} class="text-center py-1 px-1">
                {display_val(row.purchases[grade])}
              </td>
              <td class="text-center py-1 px-1 font-semibold">
                {Enum.reduce(@grades, 0, fn g, acc -> acc + to_int(row.purchases[g]) end)}
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
    <div class="space-y-6">
      <%!-- Display settings --%>
      <div class="border rounded p-4">
        <h3 class="font-bold mb-3">{gettext("Display Settings")}</h3>
        <div class="flex items-center gap-1">
          <label class="text-sm font-semibold text-gray-600">{gettext("Show ignored rows")}:</label>
          <button
            type="button"
            phx-click="toggle_show_ignored"
            class="flex items-center gap-1 px-3 py-1 rounded border text-sm font-semibold"
          >
            <.icon :if={@show_ignored} name="hero-eye" class="w-4 h-4 text-blue-600" />
            <.icon :if={!@show_ignored} name="hero-eye-slash" class="w-4 h-4 text-gray-400" />
            <span>{if @show_ignored, do: gettext("Showing"), else: gettext("Hidden")}</span>
          </button>
        </div>
      </div>

      <%!-- Lookback settings --%>
      <div class="border rounded p-4">
        <h3 class="font-bold mb-3">{gettext("Estimation Settings")}</h3>

        <.form for={%{}} id="lookback-weeks-form" phx-change="change_lookback">
          <div class="flex items-center gap-1 mb-3">
            <label class="text-sm font-semibold text-gray-600 w-64">
              {gettext("Sales/Purchase lookback weeks")}:
            </label>
            <select
              name="lookback_weeks"
              class="border rounded px-8 py-1 text-sm"
            >
              <option :for={w <- [1, 2, 3, 4]} value={w} selected={w == @lookback_weeks}>{w}</option>
            </select>
          </div>
        </.form>

        <.form for={%{}} id="autosave-delay-form" phx-change="change_autosave_delay">
          <div class="flex items-center gap-1 mb-3">
            <label class="text-sm font-semibold text-gray-600 w-64">
              {gettext("Autosave delay (seconds)")}:
            </label>
            <select
              name="autosave_delay"
              class="border rounded px-8 py-1 text-sm"
            >
              <option :for={s <- [1, 2, 3, 5, 10]} value={s} selected={s == @autosave_delay}>
                {s}
              </option>
            </select>
          </div>
        </.form>

        <.form for={%{}} id="lookback-days-form" phx-change="change_lookback_days">
          <div class="flex items-center gap-1">
            <label class="text-sm font-semibold text-gray-600 w-64">
              {gettext("Harvest/Production lookback days")}:
            </label>
            <select
              name="lookback_days"
              class="border rounded px-8 py-1 text-sm"
            >
              <option :for={d <- [2, 3, 4, 5, 6]} value={d} selected={d == @lookback_days}>
                {d}
              </option>
            </select>
          </div>
        </.form>
      </div>

      <%!-- Grades management --%>
      <div class="border rounded p-4">
        <h3 class="font-bold mb-3">{gettext("Egg Grades")}</h3>

        <.form
          for={%{}}
          id="grades-form"
          autocomplete="off"
          phx-change="validate_grades"
          phx-submit="save_grades"
        >
          <div class="max-w-md">
            <div class="flex gap-1 mb-2 text-sm font-semibold text-gray-600">
              <div class="w-8">#</div>
              <div class="w-48">{gettext("Good Name")}</div>
              <div class="w-32">{gettext("Nickname")}</div>
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
                <span class="w-8 text-sm text-gray-500">{idx + 1}</span>

                <input
                  type="text"
                  id={"grade-name-#{idx}"}
                  name={"grades[#{idx}][name]"}
                  value={grade["name"]}
                  class="w-48 border rounded px-2 py-1"
                  phx-hook="tributeAutoComplete"
                  url={"/list/companies/#{@current_company.id}/#{@current_user.id}/autocomplete?schema=good&name="}
                />

                <input
                  type="text"
                  name={"grades[#{idx}][nickname]"}
                  value={grade["nickname"]}
                  class="w-32 border rounded px-2 py-1"
                />

                <button
                  type="button"
                  phx-click="move_grade"
                  phx-value-index={idx}
                  phx-value-dir="up"
                  class="text-gray-500 hover:text-gray-700"
                >
                  <.icon name="hero-chevron-up-solid" class="h-4 w-4" />
                </button>
                <button
                  type="button"
                  phx-click="move_grade"
                  phx-value-index={idx}
                  phx-value-dir="down"
                  class="text-gray-500 hover:text-gray-700"
                >
                  <.icon name="hero-chevron-down-solid" class="h-4 w-4" />
                </button>
                <button
                  type="button"
                  phx-click="delete_grade"
                  phx-value-index={idx}
                  class="text-red-500 hover:text-red-700"
                >
                  <.icon name="hero-trash-solid" class="h-4 w-4" />
                </button>
              </div>
            </div>

            <div class="flex gap-1 mt-3">
              <button type="button" phx-click="add_grade" class="text-blue-600 hover:text-blue-800">
                <.icon name="hero-plus-circle" class="h-5 w-5" /> {gettext("Add Grade")}
              </button>
              <button type="submit" class="blue button">{gettext("Save")}</button>
            </div>
          </div>
        </.form>
      </div>
    </div>
    """
  end
end
