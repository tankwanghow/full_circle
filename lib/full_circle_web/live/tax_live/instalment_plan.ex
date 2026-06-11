defmodule FullCircleWeb.TaxLive.InstalmentPlan do
  use FullCircleWeb, :live_view
  alias FullCircle.Tax
  alias FullCircle.Tax.InstalmentPlan
  alias FullCircle.Reporting.ProfitLossForecast, as: PLF

  @impl true
  def mount(_params, _session, socket) do
    # Admin guard: this page writes to the DB, so only admins may access it.
    if socket.assigns.current_role != "admin" do
      {:ok,
       socket
       |> put_flash(:error, gettext("You are not authorised to perform this action"))
       |> push_navigate(to: "/companies/#{socket.assigns.current_company.id}")}
    else
      {:ok, assign(socket, page_title: gettext("Tax Instalment Plan"))}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    # Defensive: re-check admin in case handle_params is reached without a fresh mount.
    if socket.assigns.current_role != "admin" do
      {:noreply, socket}
    else
      do_handle_params(params, socket)
    end
  end

  defp do_handle_params(params, socket) do
    com = socket.assigns.current_company
    today = Date.utc_today()
    fy_year = safe_int(params["fy_year"], default_fy_year(com))

    as_of =
      case Date.from_iso8601(to_string(params["as_of"] || "")) do
        {:ok, d} -> d
        _ -> today
      end

    {:noreply, socket |> assign(fy_year: fy_year, as_of: as_of) |> load(com, fy_year, as_of)}
  end

  defp load(socket, com, fy_year, as_of) do
    plan =
      Tax.get_plan(com, fy_year) ||
        %InstalmentPlan{
          fy_year: fy_year,
          tolerance_pct: Decimal.new(30),
          estimate: Decimal.new(0),
          estimate_month: Tax.current_fy_month(com, fy_year, as_of),
          paid_overrides: %{}
        }

    tolerance = plan.tolerance_pct || Decimal.new(30)
    forecast_tax = Tax.forecast_annual_tax(com, fy_year, as_of)
    suggested = Tax.suggested_estimate(forecast_tax, tolerance)

    estimate =
      if Decimal.compare(plan.estimate || Decimal.new(0), Decimal.new(0)) == :gt,
        do: plan.estimate,
        else: suggested

    plan = %{plan | estimate: estimate}

    account_name = resolve_account_name(plan)

    assign(socket,
      plan: plan,
      forecast_tax: forecast_tax,
      suggested: suggested,
      schedule: schedule_for(plan, com),
      under: Tax.under_estimated?(estimate, forecast_tax, tolerance),
      account_name: account_name
    )
  end

  defp schedule_for(%InstalmentPlan{id: nil} = plan, com) do
    Tax.build_schedule(
      PLF.fy_month_bounds(com, plan.fy_year),
      %{},
      plan.estimate || Decimal.new(0),
      plan.estimate_month || 1
    )
  end

  defp schedule_for(plan, com), do: Tax.schedule(plan, com)

  defp resolve_account_name(%InstalmentPlan{tax_paid_account_id: nil}), do: ""
  defp resolve_account_name(%InstalmentPlan{tax_paid_account_id: id}) when not is_nil(id) do
    case FullCircle.Repo.get(FullCircle.Accounting.Account, id) do
      nil -> ""
      acc -> acc.name
    end
  end

  defp resolve_account_name(_), do: ""

  @impl true
  def handle_event("query", %{"fy_year" => fy, "as_of" => as_of}, socket) do
    {:noreply,
     push_navigate(socket,
       to:
         "/companies/#{socket.assigns.current_company.id}/tax_instalment_plan?#{URI.encode_query(%{fy_year: fy, as_of: as_of})}"
     )}
  end

  @impl true
  def handle_event(
        "validate",
        %{"_target" => ["plan", "tax_paid_account_name"], "plan" => params},
        socket
      ) do
    {params, socket, _} =
      FullCircleWeb.Helpers.assign_autocomplete_id(
        socket,
        params,
        "tax_paid_account_name",
        "tax_paid_account_id",
        &FullCircle.Accounting.get_account_by_name/3
      )

    # Write resolved id back into the plan struct so the hidden field renders the
    # latest value (not the stale/nil value that was there before the user typed).
    plan = %{socket.assigns.plan | tax_paid_account_id: params["tax_paid_account_id"]}

    {:noreply,
     assign(socket,
       plan: plan,
       account_name: params["tax_paid_account_name"] || ""
     )}
  end

  def handle_event("validate", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("revise", _params, socket) do
    com = socket.assigns.current_company
    fy = socket.assigns.fy_year
    as_of = socket.assigns.as_of
    forecast_tax = Tax.forecast_annual_tax(com, fy, as_of)
    plan = socket.assigns.plan
    tolerance = plan.tolerance_pct || Decimal.new(30)
    suggested = Tax.suggested_estimate(forecast_tax, tolerance)

    attrs = %{
      "fy_year" => fy,
      "estimate" => Decimal.to_string(suggested),
      "estimate_month" => Tax.current_fy_month(com, fy, as_of),
      "tolerance_pct" => Decimal.to_string(tolerance),
      "paid_overrides" => plan.paid_overrides || %{}
    }

    attrs =
      if plan.tax_paid_account_id,
        do: Map.put(attrs, "tax_paid_account_id", plan.tax_paid_account_id),
        else: attrs

    {:noreply, save_plan(socket, attrs)}
  end

  @impl true
  def handle_event("save", %{"plan" => params}, socket) do
    # Saving snapshots all 12 paid cells (incl. GL-prefilled values) as overrides;
    # after a save those amounts are frozen and no longer track new GL postings.
    {:noreply, save_plan(socket, params)}
  end

  defp save_plan(socket, params) do
    com = socket.assigns.current_company

    case Tax.create_or_update_plan(params, com, socket.assigns.current_user) do
      {:ok, _plan} -> load(socket, com, socket.assigns.fy_year, socket.assigns.as_of)
      {:error, _cs} -> put_flash(socket, :error, gettext("Could not save plan."))
    end
  end

  defp default_fy_year(com) do
    today = Date.utc_today()
    fy_end_this = PLF.prev_close(com, today.year + 1)
    if Date.compare(today, fy_end_this) != :gt, do: today.year, else: today.year + 1
  end

  defp safe_int(s, default) do
    case Integer.parse(to_string(s)) do
      {n, _} when n > 0 -> n
      _ -> default
    end
  end

  # Round to 2dp then delimit for display. Does NOT mutate stored values.
  defp money(%Decimal{} = d),
    do: Number.Delimit.number_to_delimited(Decimal.round(d, 2))

  defp money(nil), do: "0.00"
  defp money(other), do: to_string(other)

  @impl true
  def render(assigns) do
    ~H"""
    <div class="w-full px-4 mx-auto mb-10">
      <p class="text-2xl text-center font-medium">{@page_title}</p>

      <%!-- Query form --%>
      <div class="border rounded bg-amber-200 dark:bg-amber-900 dark:border-amber-700 text-center p-2 w-10/12 mx-auto">
        <.form for={%{}} id="query-form" phx-submit="query" autocomplete="off">
          <div class="grid grid-cols-12 gap-2">
            <div class="col-span-2">
              <.input
                label={gettext("For The Year")}
                name="fy_year"
                type="number"
                id="query_fy_year"
                value={@fy_year}
              />
            </div>
            <div class="col-span-2">
              <.input
                label={gettext("As Of")}
                name="as_of"
                type="date"
                id="query_as_of"
                value={Date.to_iso8601(@as_of)}
              />
            </div>
            <div class="col-span-2 mt-6 flex items-start">
              <.button>{gettext("Query")}</.button>
            </div>
          </div>
        </.form>
        <p class="text-sm text-gray-600 dark:text-gray-300 mt-2 text-left">
          {gettext(
            "CP204 planning aid built on the P&L forecast's estimated tax (an accounting-profit proxy, not a filed tax computation). 'Tax paid' sums postings to the nominated GL account — debits add, credits/refunds subtract."
          )}
        </p>
      </div>

      <%!-- Under-estimation banner --%>
      <div
        :if={@under}
        class="mt-2 w-10/12 mx-auto rounded border border-red-400 bg-red-100 dark:bg-red-950/40 dark:border-red-700 px-3 py-2 text-red-700 dark:text-red-400 font-medium"
      >
        {gettext(
          "Chosen estimate is below the penalty-free floor — under-estimation penalty risk."
        )}
      </div>

      <%!-- Plan form --%>
      <.form
        for={%{}}
        id="plan-form"
        phx-change="validate"
        phx-submit="save"
        autocomplete="off"
        class="w-10/12 mx-auto mt-3"
      >
        <div class="border rounded bg-amber-50 dark:bg-amber-950/30 dark:border-amber-800 p-3 mb-3">
          <div class="grid grid-cols-2 md:grid-cols-4 gap-3 items-end">
            <div>
              <p class="text-xs text-gray-500 dark:text-gray-400">{gettext("Forecast annual tax")}</p>
              <p class="font-mono font-semibold text-sm">{money(@forecast_tax)}</p>
            </div>
            <div>
              <p class="text-xs text-gray-500 dark:text-gray-400">{gettext("Suggested estimate (tolerance-adjusted)")}</p>
              <p class="font-mono text-sm">{money(@suggested)}</p>
            </div>
            <div>
              <.input
                name="plan[tolerance_pct]"
                id="plan_tolerance_pct"
                type="number"
                step="0.01"
                min="0"
                label={gettext("Tolerance %")}
                value={Decimal.to_string(@plan.tolerance_pct || Decimal.new(30))}
              />
            </div>
            <div>
              <.input
                name="plan[estimate]"
                id="plan_estimate"
                type="number"
                step="0.01"
                min="0"
                label={gettext("Chosen estimate")}
                value={Decimal.to_string(@plan.estimate || Decimal.new(0))}
              />
            </div>
          </div>
          <div class="grid grid-cols-2 md:grid-cols-4 gap-3 items-end mt-2">
            <div class="col-span-2">
              <input type="hidden" name="plan[tax_paid_account_id]" value={@plan.tax_paid_account_id} />
              <.input
                name="plan[tax_paid_account_name]"
                id="plan_tax_paid_account_name"
                label={gettext("Tax paid GL account")}
                value={@account_name}
                phx-hook="tributeAutoComplete"
                url={"/list/companies/#{@current_company.id}/#{@current_user.id}/autocomplete?schema=account&name="}
              />
            </div>
            <input type="hidden" name="plan[fy_year]" value={@fy_year} />
            <input type="hidden" name="plan[estimate_month]" value={@plan.estimate_month || 1} />
            <div class="flex gap-2 items-end">
              <.button class="blue button">{gettext("Save")}</.button>
              <button type="button" phx-click="revise" class="gray button">
                {gettext("Revise")}
              </button>
            </div>
          </div>
        </div>

        <%!-- Instalment schedule table --%>
        <div class="overflow-x-auto">
          <table class="text-sm text-right border dark:border-gray-700 whitespace-nowrap w-full">
            <thead class="bg-gray-200 dark:bg-gray-700 dark:text-gray-100">
              <tr>
                <th class="px-2 text-left">{gettext("Month")}</th>
                <th class="px-2">{gettext("Instalment Due")}</th>
                <th class="px-2">{gettext("Tax Paid (editable)")}</th>
                <th class="px-2">{gettext("Balance")}</th>
              </tr>
            </thead>
            <tbody>
              <tr
                :for={r <- @schedule}
                class="border-b dark:border-gray-700 odd:bg-white even:bg-gray-50 dark:odd:bg-gray-800 dark:even:bg-gray-900"
              >
                <td class="px-2 text-left">
                  {Date.to_iso8601(r.period_start)} → {Date.to_iso8601(r.period_end)}
                </td>
                <td class="px-2 font-mono">{money(r.instalment_due)}</td>
                <td class="px-2 font-mono">
                  <input
                    type="number"
                    step="0.01"
                    name={"plan[paid_overrides][#{r.month_no}]"}
                    value={Decimal.to_string(Decimal.round(r.paid, 2))}
                    class="w-32 text-right border rounded px-1 dark:bg-gray-700 dark:border-gray-600 dark:text-gray-100"
                  />
                </td>
                <td class="px-2 font-mono">{money(r.balance)}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </.form>
    </div>
    """
  end
end
