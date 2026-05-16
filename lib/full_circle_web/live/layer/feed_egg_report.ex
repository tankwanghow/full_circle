defmodule FullCircleWeb.LayerLive.FeedEggReport do
  use FullCircleWeb, :live_view

  alias FullCircle.Layer

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(result: waiting_for_async_action_map())}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    params = params["search"] || %{}
    f_date = params["f_date"] || ""
    t_date = params["t_date"] || ""
    group_days = params["group_days"] || "1"
    glist = params["glist"] || Enum.join(Layer.default_feed_good_names(), ",")

    socket =
      socket
      |> assign(page_title: gettext("Feed Consumption vs Egg Production"))
      |> assign(
        search: %{f_date: f_date, t_date: t_date, group_days: group_days, glist: glist}
      )

    {:noreply,
     if t_date == "" or f_date == "" do
       socket
     else
       socket |> filter_objects(f_date, t_date, group_days, glist)
     end}
  end

  @impl true
  def handle_event("changed", _, socket) do
    {:noreply,
     socket
     |> assign(result: waiting_for_async_action_map())}
  end

  @impl true
  def handle_event("query", %{"search" => search}, socket) do
    qry = %{
      "search[f_date]" => search["f_date"],
      "search[t_date]" => search["t_date"],
      "search[group_days]" => search["group_days"] || "1",
      "search[glist]" => search["glist"] || ""
    }

    url =
      "/companies/#{socket.assigns.current_company.id}/feed_egg_report?#{URI.encode_query(qry)}"

    {:noreply, socket |> push_navigate(to: url)}
  end

  defp filter_objects(socket, f_date, t_date, group_days, glist) do
    current_company = socket.assigns.current_company
    gd = parse_group_days(group_days)

    socket
    |> assign_async(
      :result,
      fn ->
        {:ok,
         %{
           result: Layer.feed_egg_report(f_date, t_date, current_company.id, gd, glist)
         }}
      end
    )
  end

  defp parse_group_days(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, _} when n >= 1 -> n
      _ -> 1
    end
  end

  defp parse_group_days(_), do: 1

  defp fmt(n, precision \\ 0) do
    Number.Delimit.number_to_delimited(n, precision: precision)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="w-11/12 mx-auto">
      <p class="text-2xl text-center font-medium">{@page_title}</p>
      <div class="border rounded bg-purple-200 text-center p-2">
        <.form for={%{}} id="search-form" phx-change="changed" phx-submit="query" autocomplete="off">
          <div class="grid grid-cols-12 tracking-tighter">
            <div class="col-span-4">
              <label>{gettext("Feed Goods")}</label>
              <.input
                id="search_glist"
                name="search[glist]"
                type="search"
                value={@search.glist}
                placeholder="A1,A2,A3,..."
                phx-hook="localStorageInput"
                data-ls-key="feed_egg_report_glist"
              />
            </div>
            <div class="col-span-3">
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
            <div class="col-span-2">
              <.input
                label={gettext("Group Days")}
                name="search[group_days]"
                type="number"
                min="1"
                id="search_group_days"
                value={@search.group_days}
              />
            </div>
            <div class="col-span-1 mt-6">
              <.button>{gettext("Query")}</.button>
            </div>
          </div>
        </.form>
      </div>

      <.async_html result={@result}>
        <:result_html>
          <% widths = ~w(15% 5% 8% 9% 9% 10% 9% 9% 9% 9% 8%) %>
          {FullCircleWeb.CsvHtml.headers(
            [
              gettext("Period"),
              gettext("Days"),
              gettext("Feed (T)"),
              gettext("Trays (gross)"),
              gettext("Graded (Trays)"),
              gettext("Saleable Trays"),
              gettext("Eggs/T (Gross)"),
              gettext("Eggs/T (Net)"),
              gettext("Egg Mass (kg)"),
              gettext("FCR"),
              gettext("FCR (net)")
            ],
            "font-medium flex flex-row text-center tracking-tighter mb-1",
            widths,
            "border rounded bg-gray-200 border-gray-400 px-2 py-1",
            assigns
          )}

          <div id="lists">
            <%= for row <- @result.result.rows do %>
              <div class="flex flex-row text-center tracking-tighter">
                <div class="w-[15%] border rounded bg-blue-200 border-blue-400 px-2 py-1">
                  <%= if Date.compare(row.from_date, row.to_date) == :eq do %>
                    {row.from_date}
                  <% else %>
                    {row.from_date} → {row.to_date}
                  <% end %>
                </div>
                <div class="w-[5%] border rounded bg-blue-200 border-blue-400 px-2 py-1">
                  {row.days}
                </div>
                <div class="w-[8%] border rounded bg-blue-200 border-blue-400 px-2 py-1">
                  {fmt(row.feed_tons, 3)}
                </div>
                <div class="w-[9%] border rounded bg-blue-200 border-blue-400 px-2 py-1">
                  {fmt(row.trays)}
                </div>
                <div class="w-[9%] border rounded bg-blue-200 border-blue-400 px-2 py-1">
                  {fmt(row.graded_trays)}
                </div>
                <div class="w-[10%] border rounded bg-blue-200 border-blue-400 px-2 py-1">
                  {fmt(row.net_trays)}
                </div>
                <div class="w-[9%] border rounded bg-blue-200 border-blue-400 px-2 py-1">
                  {fmt(row.eggs_per_ton_gross)}
                </div>
                <div class="w-[9%] border rounded bg-blue-200 border-blue-400 px-2 py-1">
                  {fmt(row.eggs_per_ton_net)}
                </div>
                <div class="w-[9%] border rounded bg-blue-200 border-blue-400 px-2 py-1">
                  {fmt(row.graded_mass_kg, 1)}
                </div>
                <div class="w-[9%] border rounded bg-blue-200 border-blue-400 px-2 py-1">
                  {fmt(row.fcr, 3)}
                </div>
                <div class="w-[8%] border rounded bg-blue-200 border-blue-400 px-2 py-1">
                  {fmt(row.fcr_net, 3)}
                </div>
              </div>
            <% end %>
          </div>

          <div :if={Enum.count(@result.result.rows) > 0} id="footer">
            <div class="flex flex-row text-center font-bold tracking-tighter mt-1">
              <div class="w-[15%] border rounded bg-amber-200 border-amber-400 px-2 py-1">
                {gettext("Total")}
              </div>
              <div class="w-[5%] border rounded bg-amber-200 border-amber-400 px-2 py-1">
                {@result.result.total.days}
              </div>
              <div class="w-[8%] border rounded bg-amber-200 border-amber-400 px-2 py-1">
                {fmt(@result.result.total.feed_tons, 3)}
              </div>
              <div class="w-[9%] border rounded bg-amber-200 border-amber-400 px-2 py-1">
                {fmt(@result.result.total.trays)}
              </div>
              <div class="w-[9%] border rounded bg-amber-200 border-amber-400 px-2 py-1">
                {fmt(@result.result.total.graded_trays)}
              </div>
              <div class="w-[10%] border rounded bg-amber-200 border-amber-400 px-2 py-1">
                {fmt(@result.result.total.net_trays)}
              </div>
              <div class="w-[9%] border rounded bg-amber-200 border-amber-400 px-2 py-1">
                {fmt(@result.result.total.eggs_per_ton_gross)}
              </div>
              <div class="w-[9%] border rounded bg-amber-200 border-amber-400 px-2 py-1">
                {fmt(@result.result.total.eggs_per_ton_net)}
              </div>
              <div class="w-[9%] border rounded bg-amber-200 border-amber-400 px-2 py-1">
                {fmt(@result.result.total.graded_mass_kg, 1)}
              </div>
              <div class="w-[9%] border rounded bg-amber-200 border-amber-400 px-2 py-1">
                {fmt(@result.result.total.fcr, 3)}
              </div>
              <div class="w-[8%] border rounded bg-amber-200 border-amber-400 px-2 py-1">
                {fmt(@result.result.total.fcr_net, 3)}
              </div>
            </div>
          </div>
        </:result_html>
      </.async_html>
    </div>
    """
  end
end
