defmodule FullCircleWeb.ReportLive.EpfSocsoEis do
  use FullCircleWeb, :live_view

  alias FullCircle.HR

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(page_title: "EPF/SOCSO/EIS")
      |> assign(
        settings:
          FullCircle.Sys.load_settings(
            "EpfSocsoEis",
            socket.assigns.current_company,
            socket.assigns.current_user
          )
      )

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    params = params["search"] || %{}

    report = params["report"] || setting_value(socket.assigns.settings, "report", "EPF")
    month = params["month"] || Timex.today().month
    year = params["year"] || Timex.today().year
    code = params["code"] || setting_value(socket.assigns.settings, code_key(report), "")

    {:noreply,
     socket
     |> assign(search: %{report: report, month: month, year: year, code: code})
     |> persist_settings(report, code)
     |> filter_transactions(report, month, year, code)}
  end

  # Contributions has no employer-code setting; nil never matches a setting code.
  defp code_key("Contributions"), do: nil
  defp code_key(report), do: FullCircle.HR.Statutory.code_key(report)

  defp setting_value(settings, key, default) do
    case Enum.find(settings, fn s -> s.code == key end) do
      nil -> default
      s -> s.value
    end
  end

  defp persist_settings(socket, report, code) do
    settings =
      Enum.map(socket.assigns.settings, fn s ->
        cond do
          s.code == "report" and s.value != report -> FullCircle.Sys.update_setting(s, report)
          s.code == code_key(report) and s.value != code -> FullCircle.Sys.update_setting(s, code)
          true -> s
        end
      end)

    assign(socket, settings: settings)
  end

  defp humanize_category(code) do
    code |> String.replace("_", " ") |> String.upcase()
  end

  @impl true
  def handle_event("changed", %{"search" => %{"report" => report}}, socket) do
    code = setting_value(socket.assigns.settings, code_key(report), "")

    {:noreply,
     socket
     |> assign(search: %{socket.assigns.search | report: report, code: code})
     |> assign(row: [])
     |> assign(col: [])}
  end

  @impl true
  def handle_event("changed", _params, socket) do
    {:noreply, socket |> assign(row: []) |> assign(col: [])}
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
    com_id = socket.assigns.current_company.id
    month = String.to_integer("#{month}")
    year = String.to_integer("#{year}")

    {col, row} =
      cond do
        report == "PCB" ->
          text = FullCircle.HR.Statutory.pcb_text(month, year, code, com_id)
          {["textstr"], text |> String.split("\r\n", trim: true) |> Enum.map(&[&1])}

        report == "Contributions" ->
          HR.contributions_report(month, year, com_id)

        true ->
          FullCircle.HR.Statutory.rows(report, month, year, code, com_id)
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
      <p class="text-2xl text-center font-medium">{"#{@page_title}"}</p>
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
                  "EIS",
                  "SOCSO+EIS",
                  "PCB",
                  "Contributions"
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
                min="1"
                max="12"
                step="1"
                required
                value={@search.month}
              />
            </div>
            <div class="col-span-2">
              <.input
                label={gettext("Year")}
                name="search[year]"
                type="number"
                id="search_year"
                min="2000"
                max="3000"
                step="1"
                required
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
                {gettext("Query")}
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
          <div class={"w-[#{trunc(Float.ceil(100/Enum.count(@col)))}%] text-center font-bold border rounded bg-gray-200 dark:bg-gray-700 border-gray-500"}>
            {if(h in ["name", "id_no", "wages", "textstr"], do: String.upcase(h), else: humanize_category(h))}
          </div>
        <% end %>
      </div>

      <%= for r <- @row do %>
        <div class="flex flex-row">
          <%= for c <- r do %>
            <div class={"w-[#{trunc(Float.ceil(100/Enum.count(@col)))}%] text-center border rounded bg-blue-200 border-blue-500"}>
              {c}
            </div>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end
end
