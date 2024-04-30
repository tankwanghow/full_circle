defmodule FullCircleWeb.ReportLive.HouseFeed do
  use FullCircleWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(page_title: "Feed Listing")

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    params = params["search"]

    report = params["report"] || ""
    month = params["month"] || ""
    year = params["year"] || ""

    {:noreply,
     socket
     |> assign(search: %{report: report, month: month, year: year})
     |> filter_transactions(report, month, year)}
  end

  @impl true
  def handle_event(
        "query",
        %{
          "search" => %{
            "report" => report,
            "month" => month,
            "year" => year
          }
        },
        socket
      ) do
    qry = %{
      "search[report]" => report,
      "search[month]" => month,
      "search[year]" => year
    }

    url =
      "/companies/#{socket.assigns.current_company.id}/house_feed?#{URI.encode_query(qry)}"

    {:noreply,
     socket
     |> push_navigate(to: url)}
  end

  defp filter_transactions(socket, _report, month, year) do
    current_company = socket.assigns.current_company

    socket
    |> assign_async(
      :result,
      fn ->
        {:ok,
         %{
           result:
             if month == "" or year == "" do
               {[], []}
             else
               FullCircle.Layer.house_feed_type_query(
                 month,
                 year,
                 current_company.id
               )
               |> FullCircle.Helpers.exec_query_row_col()
             end
         }}
      end
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="w-11/12 mx-auto mb-5">
      <p class="text-2xl text-center font-medium"><%= "#{@page_title}" %></p>
      <div class="border rounded bg-purple-200 text-center p-2">
        <.form for={%{}} id="search-form" phx-submit="query" autocomplete="off">
          <div class="flex tracking-tighter">
            <div class="w-[50%] hidden">
              <.input
                label={gettext("Good List")}
                id="search_report"
                name="search[report]"
                value={@search.report}
                phx-hook="tributeAutoComplete"
                url={"/api/companies/#{@current_company.id}/#{@current_user.id}/autocomplete?schema=good&name="}
              />
            </div>
            <div class="w-[8%]">
              <.input
                label={gettext("Month")}
                name="search[month]"
                type="number"
                min="1"
                max="12"
                step="1"
                required
                id="search_month"
                value={@search.month}
              />
            </div>
            <div class="w-[8%]">
              <.input
                label={gettext("Year")}
                name="search[year]"
                type="number"
                min="2000"
                max="3000"
                step="1"
                required
                id="search_year"
                value={@search.year}
              />
            </div>
            <div class="w-[19%] mt-5">
              <.button>
                <%= gettext("Query") %>
              </.button>
              <.link
                :if={@result.result != {[], []} and @result.result}
                class="blue button mr-1"
                navigate={
                  ~p"/companies/#{@current_company.id}/print/house_feed?month=#{@search.month}&year=#{@search.year}"
                }
                target="_blank"
              >
                Print
              </.link>

              <.link
                :if={@result.result != {[], []} and @result.result}
                navigate={
                  ~p"/companies/#{@current_company.id}/csv?report=housefeed&month=#{@search.month}&year=#{@search.year}"
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
          <% {col, row} = @result.result %>
          <div :if={Enum.count(col) > 0} class="flex flex-row">
            <%= for h <- col do %>
              <div class="w-[4%] text-center font-bold border rounded bg-gray-200 border-gray-500">
                <%= h %>
              </div>
            <% end %>
          </div>

          <%= for r <- row do %>
            <div class="flex flex-row">
              <%= for c <- r do %>
                <div class="w-[4%] text-center border rounded bg-blue-200 border-blue-500">
                  <%= c %>
                </div>
              <% end %>
            </div>
          <% end %>
        </:result_html>
      </.async_html>
    </div>
    """
  end
end
