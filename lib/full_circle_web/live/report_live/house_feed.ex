defmodule FullCircleWeb.ReportLive.HouseFeed do
  use FullCircleWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(page_title: "Feed Listing")
      |> assign(
        settings:
          FullCircle.Sys.load_settings(
            "HouseFeed",
            socket.assigns.current_company,
            socket.assigns.current_user
          )
      )

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    params = params["search"]

    report = params["report"] || ""
    field = params["field"] || "feed_type"

    feed_str =
      params["feed_str"] || Enum.at(socket.assigns.settings, 0).value

    month = params["month"] || ""
    year = params["year"] || ""

    {:noreply,
     socket
     |> assign(
       search: %{report: report, month: month, year: year, feed_str: feed_str, field: field}
     )
     |> filter_transactions(report, month, year, feed_str, field)}
  end

  @impl true
  def handle_event(
        "query",
        %{
          "search" => %{
            "report" => report,
            "month" => month,
            "year" => year,
            "field" => field,
            "feed_str" => feed_str
          }
        },
        socket
      ) do
    qry = %{
      "search[report]" => report,
      "search[month]" => month,
      "search[year]" => year,
      "search[field]" => field,
      "search[feed_str]" => feed_str
    }

    url =
      "/companies/#{socket.assigns.current_company.id}/house_feed?#{URI.encode_query(qry)}"

    {:noreply,
     socket
     |> push_navigate(to: url)}
  end

  defp filter_transactions(socket, _report, month, year, feed_str, field) do
    current_company = socket.assigns.current_company

    setting = Enum.at(socket.assigns.settings, 0)

    socket
    |> assign(settings: [FullCircle.Sys.update_setting(setting, feed_str)])
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
                 current_company.id,
                 feed_str,
                 field
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
      <p class="text-2xl text-center font-medium">{"#{@page_title}"}</p>
      <div class="border rounded bg-purple-200 text-center p-2">
        <.form for={%{}} id="search-form" phx-submit="query" autocomplete="off">
          <div class="flex tracking-tighter">
            <div class="hidden">
              <.input id="search_report" name="search[report]" value={@search.report} />
            </div>
            <div class="w-[8%]">
              <.input
                name="search[field]"
                id="search_field"
                value={@search.field}
                options={[
                  "feed_type",
                  "filling_wages",
                  "feeding_wages"
                ]}
                type="select"
                label={gettext("Field")}
              />
            </div>
            <div class="w-[40%]">
              <.input
                name="search[feed_str]"
                id="search_feed_str"
                value={@search.feed_str}
                label={gettext("Feed String")}
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
                {gettext("Query")}
              </.button>
              <.link
                :if={@result.result != {[], []} and @result.result}
                class="blue button mr-1"
                navigate={
                  ~p"/companies/#{@current_company.id}/print/house_feed?month=#{@search.month}&year=#{@search.year}&field=#{@search.field}&feed_str=#{@search.feed_str}"
                }
                target="_blank"
              >
                Print
              </.link>

              <.link
                :if={@result.result != {[], []} and @result.result}
                navigate={
                  ~p"/companies/#{@current_company.id}/csv?report=housefeed&month=#{@search.month}&year=#{@search.year}&field=#{@search.field}&feed_str=#{@search.feed_str}"
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
                {h}
              </div>
            <% end %>
          </div>

          <%= for r <- row do %>
            <div class="flex flex-row">
              <%= for c <- r do %>
                <div class="w-[4%] text-center border rounded bg-blue-200 border-blue-500">
                  {c}
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
