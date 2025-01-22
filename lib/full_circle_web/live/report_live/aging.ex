defmodule FullCircleWeb.ReportLive.Aging do
  use FullCircleWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(page_title: "Aging List")

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    params = params["search"]
    report = params["report"]
    days = params["days"] || "15"
    t_date = params["t_date"] || Timex.today()

    {:noreply,
     socket
     |> assign(search: %{report: report, t_date: t_date, days: days})
     |> filter_transactions(report, t_date, days)}
  end

  @impl true
  def handle_event(
        "query",
        %{"search" => %{"report" => report, "t_date" => t_date, "days" => days}},
        socket
      ) do
    qry = %{"search[t_date]" => t_date, "search[report]" => report, "search[days]" => days}

    url =
      "/companies/#{socket.assigns.current_company.id}/aging?#{URI.encode_query(qry)}"

    {:noreply,
     socket
     |> push_navigate(to: url)}
  end

  defp filter_transactions(socket, report, t_date, days) do
    days = String.to_integer(days)

    current_company = socket.assigns.current_company

    socket
    |> assign(days: days)
    |> assign_async(
      :result,
      fn ->
        {:ok,
         %{
           result:
             cond do
               report == "Debtors Aging" ->
                 FullCircle.Reporting.debtor_aging_report(
                   t_date,
                   days,
                   current_company.id
                 )

               report == "Creditors Aging" ->
                 FullCircle.Reporting.creditor_aging_report(
                   t_date,
                   days,
                   current_company.id
                 )

               true ->
                 []
             end
         }}
      end
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="w-8/12 mx-auto">
      <p class="text-2xl text-center font-medium">{"#{@page_title}"}</p>
      <div class="border rounded bg-amber-200 text-center p-2">
        <.form for={%{}} id="search-form" phx-submit="query" autocomplete="off">
          <div class="grid grid-cols-12 tracking-tighter">
            <div class="col-span-3  ">
              <.input
                name="search[report]"
                id="search_report"
                value={@search.report}
                options={[
                  "Debtors Aging",
                  "Creditors Aging"
                ]}
                type="select"
                label={gettext("Report")}
              />
            </div>
            <div class="col-span-1">
              <.input
                label={gettext("Days")}
                name="search[days]"
                type="number"
                id="search_days"
                step="1"
                value={@search.days}
              />
            </div>
            <div class="col-span-2">
              <.input
                label={gettext("To")}
                name="search[t_date]"
                type="date"
                id="search_t_date"
                value={@search.t_date}
              />
            </div>
            <div class="col-span-4 mt-6">
              <.button>
                {gettext("Query")}
              </.button>
              <.link
                :if={@result.ok? and Enum.count(@result.result) > 0}
                navigate={
                  ~p"/companies/#{@current_company.id}/csv?report=aging&rep=#{@search.report}&tdate=#{@search.t_date}&days=#{@search.days}"
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
              gettext("Category"),
              gettext("Account"),
              "#{@days} days",
              "#{@days * 2} days",
              "#{@days * 3} days",
              "#{@days * 4} days",
              "#{@days * 5} days",
              gettext("Total"),
              gettext("PD Amt"),
              gettext("Chqs")
            ],
            "font-medium flex flex-row text-center tracking-tighter mb-1",
            ["11%", "25%", "8%", "8%", "8%", "8%", "8%", "10%", "10%", "4%"],
            "border rounded bg-gray-200 border-gray-400 px-2 py-1",
            assigns
          )}

          {FullCircleWeb.CsvHtml.data(
            [
              :category,
              :contact_name,
              :p1,
              :p2,
              :p3,
              :p4,
              :p5,
              :total,
              :pd_amt,
              :pd_chqs
            ],
            @result.result,
            [
              nil,
              nil,
              &Number.Delimit.number_to_delimited/1,
              &Number.Delimit.number_to_delimited/1,
              &Number.Delimit.number_to_delimited/1,
              &Number.Delimit.number_to_delimited/1,
              &Number.Delimit.number_to_delimited/1,
              &Number.Delimit.number_to_delimited/1,
              &Number.Delimit.number_to_delimited/1,
              nil
            ],
            "flex flex-row text-center tracking-tighter max-h-20",
            ["11%", "25%", "8%", "8%", "8%", "8%", "8%", "10%", "10%", "4%"],
            "border rounded bg-blue-200 border-blue-400 px-2 py-1",
            assigns
          )}
          <div class="mb-10" />
        </:result_html>
      </.async_html>
    </div>
    """
  end
end
