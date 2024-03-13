defmodule FullCircleWeb.LayerLive.HarvestWageReport do
  use FullCircleWeb, :live_view

  alias FullCircle.{Layer}

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    params = params["search"]

    f_date = params["f_date"] || Timex.today() |> Timex.format!("%Y-%m-%d", :strftime)
    t_date = params["t_date"] || Timex.today() |> Timex.format!("%Y-%m-%d", :strftime)

    {:noreply,
     socket
     |> assign(page_title: "Harvest Wges Report :- #{f_date} to #{t_date}")
     |> assign(search: %{f_date: f_date, t_date: t_date})
     |> filter_transactions(f_date, t_date)}
  end

  @impl true
  def handle_event(
        "query",
        %{
          "search" => %{
            "t_date" => t_date,
            "f_date" => f_date
          }
        },
        socket
      ) do
    qry = %{
      "search[t_date]" => t_date,
      "search[f_date]" => f_date
    }

    url =
      "/companies/#{socket.assigns.current_company.id}/harvest_wage_report?#{URI.encode_query(qry)}"

    {:noreply,
     socket
     |> push_navigate(to: url)}
  end

  defp filter_transactions(socket, f_date, t_date) do
    current_company = socket.assigns.current_company
    socket
    |> assign_async(
      :result,
      fn ->
        {:ok,
         %{
           result:
             if t_date == "" or f_date == "" do
               []
             else
               t_date = t_date |> Timex.parse!("{YYYY}-{0M}-{0D}") |> NaiveDateTime.to_date()
               f_date = f_date |> Timex.parse!("{YYYY}-{0M}-{0D}") |> NaiveDateTime.to_date()

               Layer.harvest_wage_report(
                 f_date,
                 t_date,
                 current_company.id
               )
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
      <div class="border rounded bg-purple-200 text-center p-2">
        <.form for={%{}} id="search-form" phx-submit="query" autocomplete="off">
          <div class="grid grid-cols-12 tracking-tighter">
            <div class="col-span-2">
              <.input
                label={gettext("From")}
                name="search[f_date]"
                type="date"
                id="search_f_date"
                value={@search.f_date}
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
                <%= gettext("Query") %>
              </.button>
              <.link
                :if={@result.ok? and Enum.count(@result.result) > 0}
                class="blue button mr-1"
                navigate={
                  ~p"/companies/#{@current_company.id}/print/harvwagrepo?fdate=#{@search.f_date}&tdate=#{@search.t_date}"
                }
                target="_blank"
              >
                Print
              </.link>

              <.link
                :if={@result.ok? and Enum.count(@result.result) > 0}
                navigate={
                  ~p"/companies/#{@current_company.id}/csv?report=harvwagrepo&fdate=#{@search.f_date}&tdate=#{@search.t_date}"
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
              gettext("Date"),
              gettext("House"),
              gettext("Collector"),
              gettext("Production"),
              gettext("Wages")
            ],
            "font-medium flex flex-row text-center tracking-tighter mb-1",
            ["18%", "18%", "28%", "18%", "18%"],
            "border rounded bg-gray-200 border-gray-400 px-2 py-1",
            assigns
          ) %>

          <%= FullCircleWeb.CsvHtml.data(
            [
              :har_date,
              :house_no,
              :employee,
              :prod,
              :wages
            ],
            @result.result,
            [
              nil,
              nil,
              nil,
              fn n -> Number.Delimit.number_to_delimited(n, precision: 0) end,
              &Number.Delimit.number_to_delimited/1
            ],
            "flex flex-row text-center tracking-tighter max-h-20",
            ["18%", "18%", "28%", "18%", "18%"],
            "border rounded bg-blue-200 border-blue-400 px-2 py-1",
            assigns
          ) %>
        </:result_html>
      </.async_html>
    </div>
    """
  end
end
