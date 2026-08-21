defmodule FullCircleWeb.ReportLive.FinancialStatements do
  use FullCircleWeb, :live_view

  alias FullCircle.Reporting

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(page_title: "Financial Statements")

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    params = params["search"]
    report = params["report"]
    f_date = params["f_date"] || default_f_date(socket.assigns.current_company)
    t_date = params["t_date"] || Date.to_iso8601(Timex.today())

    {:noreply,
     socket
     |> assign(search: %{report: report, f_date: f_date, t_date: t_date})
     |> filter_transactions(report, f_date, t_date)}
  end

  @impl true
  def handle_event(
        "query",
        %{"search" => %{"report" => report, "f_date" => f_date, "t_date" => t_date}},
        socket
      ) do
    qry = %{"search[f_date]" => f_date, "search[t_date]" => t_date, "search[report]" => report}

    url =
      "/companies/#{socket.assigns.current_company.id}/financial_statements?#{URI.encode_query(qry)}"

    {:noreply,
     socket
     |> push_navigate(to: url)}
  end

  defp default_f_date(com) do
    Reporting.prev_close_date(Timex.today(), com) |> Date.add(1) |> Date.to_iso8601()
  end

  defp to_date(%Date{} = date), do: date

  defp to_date(date) when is_binary(date) do
    case Date.from_iso8601(date) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp to_date(_), do: nil

  defp filter_transactions(socket, report, f_date, t_date) do
    current_company = socket.assigns.current_company
    f_date = to_date(f_date)
    t_date = to_date(t_date)

    socket
    |> assign_async(
      [:result, :cash_start, :cash_end],
      fn ->
        {result, cash_start, cash_end} =
          cond do
            is_nil(t_date) ->
              {[], nil, nil}

            report == "Trail Balance" ->
              {Reporting.trail_balance(t_date, current_company), nil, nil}

            report == "Profit Loss" ->
              {Reporting.profit_loss(t_date, current_company), nil, nil}

            report == "Balance Sheet" ->
              {Reporting.balance_sheet(t_date, current_company), nil, nil}

            report == "Cash Flow" and not is_nil(f_date) ->
              {Reporting.cash_flow(f_date, t_date, current_company),
               Reporting.cash_balance(Date.add(f_date, -1), current_company),
               Reporting.cash_balance(t_date, current_company)}

            true ->
              {[], nil, nil}
          end

        {:ok, %{result: result, cash_start: cash_start, cash_end: cash_end}}
      end
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="w-6/12 mx-auto">
      <p class="text-2xl text-center font-medium">{"#{@page_title}"}</p>
      <div class="border rounded bg-amber-200 text-center p-2">
        <.form for={%{}} id="search-form" phx-submit="query" autocomplete="off">
          <div class="grid grid-cols-12 tracking-tighter">
            <div class="col-span-3">
              <.input
                name="search[report]"
                id="search_report"
                value={@search.report}
                options={[
                  "Trail Balance",
                  "Profit Loss",
                  "Balance Sheet",
                  "Cash Flow"
                ]}
                type="select"
                label={gettext("Report")}
              />
            </div>
            <div class="col-span-3">
              <.input
                label={gettext("From")}
                name="search[f_date]"
                type="date"
                id="search_f_date"
                value={@search.f_date}
              />
            </div>
            <div class="col-span-3">
              <.input
                label={gettext("To")}
                name="search[t_date]"
                type="date"
                id="search_t_date"
                value={@search.t_date}
              />
            </div>
            <div class="col-span-3 mt-6">
              <.button>
                {gettext("Query")}
              </.button>
              <.link
                :if={@result.ok? and Enum.count(@result.result) > 0}
                navigate={
                  ~p"/companies/#{@current_company.id}/csv?report=financial_statements&rep=#{@search.report}&fdate=#{@search.f_date}&tdate=#{@search.t_date}"
                }
                target="_blank"
                class="blue button"
              >
                CSV
              </.link>
            </div>
          </div>
        </.form>
      </div>

      <.async_html result={@result}>
        <:result_html>
          {FullCircleWeb.CsvHtml.headers(
            [
              gettext("Type"),
              gettext("Account"),
              gettext("Balance")
            ],
            "font-medium flex flex-row text-center tracking-tighter mb-1",
            ["20%", "60%", "20%"],
            "border rounded bg-gray-200 border-gray-400 px-2 py-1",
            assigns
          )}

          {FullCircleWeb.CsvHtml.data(
            [
              :type,
              :name,
              :balance
            ],
            @result.result,
            [nil, nil, &Number.Delimit.number_to_delimited/1],
            "flex flex-row text-center tracking-tighter max-h-20",
            ["20%", "60%", "20%"],
            "border rounded bg-blue-200 border-blue-400 px-2 py-1",
            assigns
          )}

          <div id="footer" class="mb-5">
            <div class="flex flex-row text-center tracking-tighter mt-1">
              <div class="w-[80%] border px-2 py-1 text-right font-bold rounded bg-lime-200 border-lime-400">
                {if @search.report == "Cash Flow",
                  do: gettext("Net Cash Change"),
                  else: gettext("Balance")}
              </div>
              <div class="w-[20%] font-bold border rounded bg-lime-200 border-lime-400 text-center px-2 py-1">
                {Enum.reduce(@result.result, Decimal.new("0"), fn obj, acc ->
                  Decimal.add(obj.balance, acc)
                end)
                |> Number.Delimit.number_to_delimited()}
              </div>
            </div>
            <div
              :if={@search.report == "Cash Flow" and @cash_start.ok? and !is_nil(@cash_start.result)}
              class="flex flex-row text-center tracking-tighter mt-1"
            >
              <div class="w-[80%] border px-2 py-1 text-right font-bold rounded bg-lime-200 border-lime-400">
                {gettext("Cash at Beginning of Period")}
              </div>
              <div class="w-[20%] font-bold border rounded bg-lime-200 border-lime-400 text-center px-2 py-1">
                {Number.Delimit.number_to_delimited(@cash_start.result)}
              </div>
            </div>
            <div
              :if={@search.report == "Cash Flow" and @cash_end.ok? and !is_nil(@cash_end.result)}
              class="flex flex-row text-center tracking-tighter mt-1"
            >
              <div class="w-[80%] border px-2 py-1 text-right font-bold rounded bg-lime-200 border-lime-400">
                {gettext("Cash at End of Period")}
              </div>
              <div class="w-[20%] font-bold border rounded bg-lime-200 border-lime-400 text-center px-2 py-1">
                {Number.Delimit.number_to_delimited(@cash_end.result)}
              </div>
            </div>
          </div>
        </:result_html>
      </.async_html>
    </div>
    """
  end
end
