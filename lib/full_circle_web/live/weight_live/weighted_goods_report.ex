defmodule FullCircleWeb.WeighingLive.GoodsReport do
  use FullCircleWeb, :live_view

  alias FullCircle.{WeightBridge}

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    params = params["search"]
    glist = params["glist"] || ""
    f_date = params["f_date"] || Timex.today() |> Timex.format!("%Y-%m-01", :strftime)
    t_date = params["t_date"] || Timex.today() |> Timex.format!("%Y-%m-%d", :strftime)

    {:noreply,
     socket
     |> assign(page_title: "Weight Goods Report :- #{f_date} to #{t_date}")
     |> assign(search: %{glist: glist, f_date: f_date, t_date: t_date})
     |> filter_objects(glist, f_date, t_date)}
  end

  @impl true
  def handle_event(
        "query",
        %{
          "search" => %{
            "glist" => glist,
            "t_date" => t_date,
            "f_date" => f_date
          }
        },
        socket
      ) do
    qry = %{
      "search[glist]" => glist,
      "search[t_date]" => t_date,
      "search[f_date]" => f_date
    }

    url =
      "/companies/#{socket.assigns.current_company.id}/weighed_goods_report?#{URI.encode_query(qry)}"

    {:noreply,
     socket
     |> push_navigate(to: url)}
  end

  @impl true
  def handle_event("changed", _, socket) do
    {:noreply,
     socket
     |> assign(objects_count: 0)
     |> assign(objects: [])}
  end

  defp filter_objects(socket, glist, f_date, t_date) do
    objects =
      if t_date == "" or f_date == "" do
        []
      else
        t_date = t_date |> Timex.parse!("{YYYY}-{0M}-{0D}") |> NaiveDateTime.to_date()
        f_date = f_date |> Timex.parse!("{YYYY}-{0M}-{0D}") |> NaiveDateTime.to_date()

        WeightBridge.goods_report(
          glist,
          f_date,
          t_date,
          socket.assigns.current_company.id
        )
      end

    socket
    |> assign(objects_count: Enum.count(objects))
    |> assign(objects: objects)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="w-8/12 mx-auto">
      <p class="text-2xl text-center font-medium"><%= "#{@page_title}" %></p>
      <div class="border rounded bg-purple-200 text-center p-2">
        <.form for={%{}} id="search-form" phx-change="changed" phx-submit="query" autocomplete="off">
          <div class="grid grid-cols-12 tracking-tighter">
            <div class="col-span-5 grow shrink">
              <label class="">Search Terms</label>
              <.input
                id="search_glist"
                name="search[glist]"
                type="search"
                value={@search.glist}
                placeholder="good names..."
              />
            </div>
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
            <div class="col-span-2 mt-6">
              <.button>
                <%= gettext("Query") %>
              </.button>
              <.link
                :if={@objects_count > 0}
                navigate={
                  ~p"/companies/#{@current_company.id}/csv?report=weigoodrepo&glist=#{@search.glist}&fdate=#{@search.f_date}&tdate=#{@search.t_date}"
                }
                class="blue button"
                target="_blank"
              >
                CSV
              </.link>
            </div>
          </div>
        </.form>
      </div>

      <%= FullCircleWeb.CsvHtml.headers(
        [
          gettext("Month"),
          gettext("Year"),
          gettext("Goods"),
          gettext("Amount"),
          gettext("Unit")
        ],
        "font-medium flex flex-row text-center tracking-tighter mb-1",
        ["20%", "20%", "20%", "20%", "20%"],
        "border rounded bg-gray-200 border-gray-400 px-2 py-1",
        assigns
      ) %>

      <%= FullCircleWeb.CsvHtml.data(
        [
          :month,
          :year,
          :good_name,
          :total,
          :unit
        ],
        @objects,
        [nil, nil, nil, fn n -> Number.Delimit.number_to_delimited(n, precision: 0) end, nil],
        "flex flex-row text-center tracking-tighter max-h-20",
        ["20%", "20%", "20%", "20%", "20%"],
        "border rounded bg-blue-200 border-blue-400 px-2 py-1",
        assigns
      ) %>
    </div>
    """
  end
end
