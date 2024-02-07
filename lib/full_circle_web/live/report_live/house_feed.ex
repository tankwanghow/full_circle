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
    f_date = params["f_date"] || ""
    t_date = params["t_date"] || ""

    {:noreply,
     socket
     |> assign(search: %{report: report, f_date: f_date, t_date: t_date})
     |> filter_transactions(report, f_date, t_date)}
  end

  @impl true
  def handle_event(
        "query",
        %{
          "search" => %{
            "report" => report,
            "f_date" => f_date,
            "t_date" => t_date
          }
        },
        socket
      ) do
    qry = %{
      "search[report]" => report,
      "search[f_date]" => f_date,
      "search[t_date]" => t_date
    }

    url =
      "/companies/#{socket.assigns.current_company.id}/house_feed?#{URI.encode_query(qry)}"

    {:noreply,
     socket
     |> push_navigate(to: url)}
  end

  defp filter_transactions(socket, _report, f_date, t_date) do
    {col, row} =
      if f_date == "" or t_date == "" do
        {[], []}
      else
        FullCircle.Layer.house_feed_type(
          f_date,
          t_date,
          socket.assigns.current_company.id
        )
      end

    socket |> assign(row: row) |> assign(col: col)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="w-11/12 mx-auto mb-5">
      <p class="text-2xl text-center font-medium"><%= "#{@page_title}" %></p>
      <div class="border rounded bg-purple-200 text-center p-2">
        <.form for={%{}} id="search-form" phx-submit="query" autocomplete="off">
          <div class="flex tracking-tighter">
            <div class="w-[59%] hidden">
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
                label={gettext("From")}
                name="search[f_date]"
                type="date"
                id="search_f_date"
                value={@search.f_date}
              />
            </div>
            <div class="w-[8%]">
              <.input
                label={gettext("To")}
                name="search[t_date]"
                type="date"
                id="search_t_date"
                value={@search.t_date}
              />
            </div>
            <div class="w-[10%] mt-5">
              <.button>
                <%= gettext("Query") %>
              </.button>
              <.link
                :if={Enum.count(@row) > 0}
                class="blue button mr-1"
                navigate={
                  ~p"/companies/#{@current_company.id}/print/house_feed?report=actrans&name=#{@search.report}&fdate=#{@search.f_date}&tdate=#{@search.t_date}"
                }
                target="_blank"
              >
                Print
              </.link>
            </div>
          </div>
        </.form>
      </div>

      <div :if={Enum.count(@col) > 0} class="flex flex-row">
        <%= for h <- @col do %>
          <div class="w-[4%] text-center font-bold border rounded bg-gray-200 border-gray-500">
            <%= h %>
          </div>
        <% end %>
      </div>

      <%= for r <- @row do %>
        <div class="flex flex-row">
          <%= for c <- r do %>
            <div class="w-[4%] text-center border rounded bg-blue-200 border-blue-500">
              <%= c %>
            </div>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end
end
