defmodule FullCircleWeb.ReportLive.EpfSocsoEis do
  use FullCircleWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(page_title: "EPF/SOCSO/EIS")

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    params = params["search"]
    report = params["report"]
    code = params["code"]
    month = (params["month"] || "#{Timex.today().month}") |> String.to_integer()
    year = (params["year"] || "#{Timex.today().year}") |> String.to_integer()

    {:noreply,
     socket
     |> assign(search: %{report: report, month: month, year: year, code: code})
     |> filter_transactions(report, month, year, code)}
  end

  @impl true
  def handle_event("changed", _, socket) do
    {:noreply,
     socket
     |> assign(objects_count: 0)
     |> assign(objects: [])}
  end

  @impl true
  def handle_event(
        "query",
        %{"search" => %{"report" => report, "month" => month, "year" => year, "code" => code}},
        socket
      ) do
    qry = %{
      "search[month]" => month,
      "search[report]" => report,
      "search[year]" => year,
      "search[code]" => code
    }

    url =
      "/companies/#{socket.assigns.current_company.id}/epfsocsoeis?#{URI.encode_query(qry)}"

    {:noreply,
     socket
     |> push_navigate(to: url)}
  end

  defp filter_transactions(socket, report, month, year, code) do
    {col, row} =
      cond do
        report == "EPF" ->
          FullCircle.HR.epf_submit_file_format_query(
            month,
            year,
            code,
            socket.assigns.current_company.id
          )

        report == "SOCSO" ->
          FullCircle.HR.socso_submit_file_format_query(
            month,
            year,
            code,
            socket.assigns.current_company.id
          )

        report == "EIS" ->
          FullCircle.HR.eis_submit_file_format_query(
            month,
            year,
            code,
            socket.assigns.current_company.id
          )

        true ->
          {[], []}
      end

    socket
    |> assign(row: row)
    |> assign(col: col)
    |> assign(row_count: Enum.count(row))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="w-8/12 mx-auto">
      <p class="text-2xl text-center font-medium"><%= "#{@page_title}" %></p>
      <div class="border rounded bg-amber-200 text-center p-2">
        <.form for={%{}} id="search-form" phx-change="changed" phx-submit="query" autocomplete="off">
          <div class="grid grid-cols-12 tracking-tighter">
            <div class="col-span-2">
              <.input
                name="search[report]"
                id="search_report"
                value={@search.report}
                options={[
                  "EPF",
                  "SOCSO",
                  "EIS"
                ]}
                type="select"
                label={gettext("Report")}
              />
            </div>
            <div class="col-span-2">
              <.input
                label={gettext("Month")}
                name="search[month]"
                type="number"
                id="search_month"
                value={@search.month}
              />
            </div>
            <div class="col-span-2">
              <.input
                label={gettext("Year")}
                name="search[year]"
                type="number"
                id="search_year"
                value={@search.year}
              />
            </div>
            <div class="col-span-2">
              <.input
                label={gettext("Code")}
                name="search[code]"
                id="search_code"
                value={@search.code}
              />
            </div>
            <div class="col-span-2 mt-6">
              <.button>
                <%= gettext("Query") %>
              </.button>
              <.link
                :if={Enum.count(@row) > 0}
                navigate={
                  ~p"/companies/#{@current_company.id}/csv?report=epfsocsoeis&rep=#{@search.report}&month=#{@search.month}&year=#{@search.year}&code=#{@search.code}"
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

      <div :if={Enum.count(@col) > 0} class="flex flex-row">
        <%= for h <- @col do %>
          <div class={"w-[#{trunc(Float.ceil(100/Enum.count(@col)))}%] text-center font-bold border rounded bg-gray-200 border-gray-500"}>
            <%= h %>
          </div>
        <% end %>
      </div>

      <%= for r <- @row do %>
        <div class="flex flex-row">
          <%= for c <- r do %>
            <div class={"w-[#{trunc(Float.ceil(100/Enum.count(@col)))}%] text-center border rounded bg-blue-200 border-blue-500"}>
              <%= c %>
            </div>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end
end
