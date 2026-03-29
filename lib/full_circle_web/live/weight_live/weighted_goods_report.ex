defmodule FullCircleWeb.WeighingLive.GoodsReport do
  use FullCircleWeb, :live_view

  alias FullCircle.{WeightBridge}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(result: waiting_for_async_action_map())}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    params = params["search"]
    glist = params["glist"] || ""
    f_date = params["f_date"] || ""
    t_date = params["t_date"] || ""
    group_note = params["group_note"] || "false"

    socket =
      socket
      |> assign(page_title: "Weight Goods Report :- #{f_date} to #{t_date}")
      |> assign(search: %{glist: glist, f_date: f_date, t_date: t_date, group_note: group_note})

    {:noreply,
     if t_date == "" or f_date == "" do
       socket
     else
       socket |> filter_objects(glist, f_date, t_date, group_note)
     end}
  end

  @impl true
  def handle_event("changed", _, socket) do
    {:noreply,
     socket
     |> assign(result: waiting_for_async_action_map())}
  end

  @impl true
  def handle_event(
        "query",
        %{
          "search" => search
        },
        socket
      ) do
    glist = search["glist"]
    f_date = search["f_date"]
    t_date = search["t_date"]
    group_note = if search["group_note"], do: "true", else: "false"

    qry = %{
      "search[glist]" => glist,
      "search[t_date]" => t_date,
      "search[f_date]" => f_date,
      "search[group_note]" => group_note
    }

    url =
      "/companies/#{socket.assigns.current_company.id}/weighed_goods_report?#{URI.encode_query(qry)}"

    {:noreply,
     socket
     |> push_navigate(to: url)}
  end

  defp filter_objects(socket, glist, f_date, t_date, group_note) do
    current_company = socket.assigns.current_company

    socket
    |> assign_async(
      :result,
      fn ->
        {:ok,
         %{
           result:
             WeightBridge.goods_report(
               glist,
               f_date,
               t_date,
               current_company.id,
               group_note
             )
         }}
      end
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="w-8/12 mx-auto">
      <p class="text-2xl text-center font-medium">{"#{@page_title}"}</p>
      <div class="border rounded bg-purple-200 text-center p-2">
        <.form for={%{}} id="search-form" phx-change="changed" phx-submit="query" autocomplete="off">
          <div class="grid grid-cols-12 tracking-tighter">
            <div class="col-span-4 grow shrink">
              <label class="">Search Terms</label>
              <.input
                id="search_glist"
                name="search[glist]"
                type="search"
                value={@search.glist}
                placeholder="good names..."
                phx-hook="localStorageInput"
                data-ls-key="weight_goods_report_glist"
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
            <div class="col-span-2 mt-6 flex items-center gap-1 pl-2">
              <input
                type="checkbox"
                name="search[group_note]"
                id="search_group_note"
                value="true"
                checked={@search.group_note == "true"}
              />
              <label for="search_group_note">{gettext("Group Note")}</label>
            </div>
            <div class="col-span-2 mt-6">
              <.button>
                {gettext("Query")}
              </.button>
              <.link
                :if={@result.ok? and Enum.count(@result.result) > 0}
                navigate={
                  ~p"/companies/#{@current_company.id}/csv?report=weigoodrepo&glist=#{@search.glist}&fdate=#{@search.f_date}&tdate=#{@search.t_date}&group_note=#{@search.group_note}"
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

      <.async_html result={@result}>
        <:result_html>
          <% {headers, fields, formatters, widths} =
            if @search.group_note == "true" do
              {[gettext("Month"), gettext("Year"), gettext("Goods"), gettext("Amount"), gettext("Unit"), gettext("Note")],
               [:month, :year, :good_name, :total, :unit, :note],
               [nil, nil, nil, fn n -> Number.Delimit.number_to_delimited(n, precision: 0) end, nil, nil],
               ["15%", "20%", "15%", "20%", "15%", "15%"]}
            else
              {[gettext("Month"), gettext("Year"), gettext("Goods"), gettext("Amount"), gettext("Unit")],
               [:month, :year, :good_name, :total, :unit],
               [nil, nil, nil, fn n -> Number.Delimit.number_to_delimited(n, precision: 0) end, nil],
               ["15%", "20%", "20%", "25%", "20%"]}
            end
          %>
          {FullCircleWeb.CsvHtml.headers(
            headers,
            "font-medium flex flex-row text-center tracking-tighter mb-1",
            widths,
            "border rounded bg-gray-200 border-gray-400 px-2 py-1",
            assigns
          )}

          {FullCircleWeb.CsvHtml.data(
            fields,
            @result.result,
            formatters,
            "flex flex-row text-center tracking-tighter max-h-20",
            widths,
            "border rounded bg-blue-200 border-blue-400 px-2 py-1",
            assigns
          )}
        </:result_html>
      </.async_html>
    </div>
    """
  end
end
