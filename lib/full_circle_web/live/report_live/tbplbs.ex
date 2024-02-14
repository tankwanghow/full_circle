defmodule FullCircleWeb.ReportLive.TbPlBs do
  use FullCircleWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(page_title: "TB/PL/BS")

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    params = params["search"]
    report = params["report"]
    t_date = params["t_date"] 

    {:noreply,
     socket
     |> assign(search: %{report: report, t_date: t_date})
     |> filter_transactions(report, t_date)}
  end

  @impl true
  def handle_event("query", %{"search" => %{"report" => report, "t_date" => t_date}}, socket) do
    qry = %{"search[t_date]" => t_date, "search[report]" => report}

    url =
      "/companies/#{socket.assigns.current_company.id}/tbplbs?#{URI.encode_query(qry)}"

    {:noreply,
     socket
     |> push_navigate(to: url)}
  end

  defp filter_transactions(socket, report, t_date) do
    [y, m, d] = t_date |> String.split("-") |> Enum.map(fn x -> String.to_integer(x) end)

    socket
    |> assign_async(
      :result,
      fn ->
        {:ok,
         %{
           result:
             cond do
               report == "Trail Balance" ->
                 FullCircle.Reporting.trail_balance(
                   Date.new!(y, m, d),
                   socket.assigns.current_company
                 )

               report == "Profit Loss" ->
                 FullCircle.Reporting.profit_loss(
                   Date.new!(y, m, d),
                   socket.assigns.current_company
                 )

               report == "Balance Sheet" ->
                 FullCircle.Reporting.balance_sheet(
                   Date.new!(y, m, d),
                   socket.assigns.current_company
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
    <div class="w-6/12 mx-auto">
      <p class="text-2xl text-center font-medium"><%= "#{@page_title}" %></p>
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
                  "Balance Sheet"
                ]}
                type="select"
                label={gettext("Report")}
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
            <div class="col-span-4 mt-6">
              <.button>
                <%= gettext("Query") %>
              </.button>
              <.link
                :if={@result.ok? and Enum.count(@result.result) > 0}
                navigate={
                  ~p"/companies/#{@current_company.id}/csv?report=tbplbs&rep=#{@search.report}&tdate=#{@search.t_date}"
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
          <%= FullCircleWeb.CsvHtml.headers(
            [
              gettext("Type"),
              gettext("Account"),
              gettext("Balance")
            ],
            "font-medium flex flex-row text-center tracking-tighter mb-1",
            ["30%", "50%", "20%"],
            "border rounded bg-gray-200 border-gray-400 px-2 py-1",
            assigns
          ) %>

          <%= FullCircleWeb.CsvHtml.data(
            [
              :type,
              :name,
              :balance
            ],
            @result.result,
            [nil, nil, &Number.Delimit.number_to_delimited/1],
            "flex flex-row text-center tracking-tighter max-h-20",
            ["30%", "50%", "20%"],
            "border rounded bg-blue-200 border-blue-400 px-2 py-1",
            assigns
          ) %>

          <div id="footer">
            <div class="flex flex-row text-center tracking-tighter mb-5 mt-1">
              <div class="w-[80%] border px-2 py-1 text-right font-bold rounded bg-lime-200 border-lime-400">
                <%= gettext("Balance") %>
              </div>
              <div class="w-[20%] font-bold border rounded bg-lime-200 border-lime-400 text-center px-2 py-1">
                <%= Enum.reduce(@result.result, Decimal.new("0"), fn obj, acc ->
                  Decimal.add(obj.balance, acc)
                end)
                |> Number.Delimit.number_to_delimited() %>
              </div>
            </div>
          </div>
        </:result_html>
      </.async_html>
    </div>
    """
  end
end
