defmodule FullCircleWeb.ReportLive.GoodSnP do
  use FullCircleWeb, :live_view

  # Combined goods sales & purchases listing.
  # type "sales":      Invoice + cash-sale Receipt lines (contact = Customer)
  # type "purchases":  PurInvoice + cash-purchase Payment lines (contact = Vendor)
  # Replaces the old ReportLive.GoodSales; /good_sales still routes here.

  @types ~w(sales purchases)

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: gettext("Goods Sales & Purchases"))}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    search = parse_search(params["search"] || %{})

    {:noreply,
     socket
     |> assign(search: search)
     |> filter_transactions(search)}
  end

  # "custom" category: goods list is replaced by two ilike pattern lists —
  # name_ilike matches good.name, desc_ilike matches the detail line
  # descriptions; a line qualifies when either group matches.
  defp parse_search(params) do
    %{
      type: if(params["type"] in @types, do: params["type"], else: "sales"),
      contact: params["contact"] || "",
      goods: params["goods"] || "",
      category: params["category"] || "",
      name_ilike: params["name_ilike"] || "",
      desc_ilike: params["desc_ilike"] || "",
      f_date: params["f_date"] || "#{Timex.today()}",
      t_date: params["t_date"] || "#{Timex.today()}"
    }
  end

  @impl true
  def handle_event("query", %{"search" => search_params}, socket) do
    s = parse_search(search_params)

    qry = %{
      "search[type]" => s.type,
      "search[contact]" => s.contact,
      "search[goods]" => s.goods,
      "search[category]" => s.category,
      "search[name_ilike]" => s.name_ilike,
      "search[desc_ilike]" => s.desc_ilike,
      "search[f_date]" => s.f_date,
      "search[t_date]" => s.t_date
    }

    url =
      "/companies/#{socket.assigns.current_company.id}/good_snp?#{URI.encode_query(qry)}"

    {:noreply, push_navigate(socket, to: url)}
  end

  @impl true
  def handle_event(
        "change",
        %{"_target" => ["search", "category"], "search" => search_params},
        socket
      ) do
    s = parse_search(search_params)

    s =
      if s.category == "custom" do
        # user enters ilike patterns; keep whatever is typed
        s
      else
        goods =
          FullCircle.Product.get_goods_by_category(
            s.category,
            socket.assigns.current_company,
            socket.assigns.current_user
          )

        goods =
          if Enum.count(goods) > 0 do
            goods |> Enum.map_join(", ", fn x -> x.name end)
          else
            ["Not Goods in this category"]
          end

        %{s | goods: goods}
      end

    {:noreply, assign(socket, search: s)}
  end

  @impl true
  def handle_event("change", _, socket) do
    {:noreply, socket}
  end

  defp query_opts(%{category: "custom"} = search) do
    [match: :ilike, name_ilike: search.name_ilike, desc_ilike: search.desc_ilike]
  end

  defp query_opts(_search), do: []

  defp filter_transactions(socket, search) do
    current_company = socket.assigns.current_company
    %{type: type, contact: contact, goods: goods, f_date: f_date, t_date: t_date} = search
    opts = query_opts(search)

    socket
    |> assign_async(
      :result,
      fn ->
        {:ok,
         %{
           result:
             if f_date == "" or t_date == "" do
               {[], []}
             else
               case type do
                 "purchases" ->
                   {FullCircle.TaggedBill.goods_purchases_report(
                      contact,
                      goods,
                      f_date,
                      t_date,
                      current_company.id,
                      opts
                    ),
                    FullCircle.TaggedBill.goods_purchases_summary_report(
                      contact,
                      goods,
                      f_date,
                      t_date,
                      current_company.id,
                      opts
                    )}

                 _ ->
                   {FullCircle.TaggedBill.goods_sales_report(
                      contact,
                      goods,
                      f_date,
                      t_date,
                      current_company.id,
                      opts
                    ),
                    FullCircle.TaggedBill.goods_sales_summary_report(
                      contact,
                      goods,
                      f_date,
                      t_date,
                      current_company.id,
                      opts
                    )}
               end
             end
         }}
      end
    )
  end

  defp contact_label("purchases"), do: gettext("Vendor")
  defp contact_label(_), do: gettext("Customer")

  defp csv_report("purchases"), do: "goodpurchases"
  defp csv_report(_), do: "goodsales"

  @impl true
  def render(assigns) do
    ~H"""
    <div class="w-11/12 mx-auto mb-5">
      <p class="text-2xl text-center font-medium">{"#{@page_title}"}</p>
      <div class="border rounded bg-purple-200 text-center p-2">
        <.form for={%{}} id="search-form" phx-change="change" phx-submit="query" autocomplete="off">
          <div class="flex tracking-tighter">
            <div class="w-[10%]">
              <.input
                id="search_type"
                name="search[type]"
                value={@search.type}
                label={gettext("Type")}
                type="select"
                options={[{gettext("Sales"), "sales"}, {gettext("Purchases"), "purchases"}]}
              />
            </div>
            <div class="w-[10%]">
              <.input
                id="search_category"
                name="search[category]"
                value={@search.category}
                label={gettext("Category")}
                type="select"
                options={FullCircle.Product.categories() ++ ["custom"]}
              />
            </div>
            <div class="w-[30%]">
              <.input
                label={gettext("Contact")}
                id="search_contact"
                name="search[contact]"
                value={@search.contact}
                phx-hook="tributeAutoComplete"
                url={"/list/companies/#{@current_company.id}/#{@current_user.id}/autocomplete?schema=contact&name="}
              />
            </div>
            <div class="w-[10%]">
              <.input
                label={gettext("From")}
                name="search[f_date]"
                type="date"
                id="search_f_date"
                value={@search.f_date}
              />
            </div>
            <div class="w-[10%]">
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
                {gettext("Query")}
              </.button>
              <.link
                :if={@result.result != {[], []}}
                navigate={
                  ~p"/companies/#{@current_company.id}/csv?report=#{csv_report(@search.type)}&contact=#{@search.contact}&goods=#{@search.goods}&category=#{@search.category}&name_ilike=#{@search.name_ilike}&desc_ilike=#{@search.desc_ilike}&fdate=#{@search.f_date}&tdate=#{@search.t_date}"
                }
                class="blue button"
                target="_blank"
              >
                CSV
              </.link>
            </div>
          </div>
          <div :if={@search.category != "custom"} class="w-[100%]">
            <.input
              label={gettext("Good List")}
              type="textarea"
              id="search_goods"
              name="search[goods]"
              value={@search.goods}
              phx-hook="tributeAutoComplete"
              url={"/list/companies/#{@current_company.id}/#{@current_user.id}/autocomplete?schema=good&name="}
            />
          </div>
          <div :if={@search.category == "custom"} class="flex gap-2">
            <div class="w-[50%]">
              <.input
                label={gettext("Good name ilike list (e.g. %egg%, %maize%)")}
                type="textarea"
                id="search_name_ilike"
                name="search[name_ilike]"
                value={@search.name_ilike}
              />
            </div>
            <div class="w-[50%]">
              <.input
                label={gettext("Line description ilike list (e.g. %egg%, %transport%)")}
                type="textarea"
                id="search_desc_ilike"
                name="search[desc_ilike]"
                value={@search.desc_ilike}
              />
            </div>
          </div>
        </.form>
      </div>

      <.async_html result={@result}>
        <:result_html>
          <% {objects, summaries} = @result.result %>
          <div class="font-medium flex flex-row text-center tracking-tighter mb-1">
            <div class="w-[7%] border rounded bg-gray-200 border-gray-400 px-2 py-1">
              {gettext("Date")}
            </div>
            <div class="w-[7%] border rounded bg-gray-200 border-gray-400 px-2 py-1">
              {gettext("Doc No")}
            </div>
            <div class="w-[15%] border rounded bg-gray-200 border-gray-400 px-2 py-1">
              {contact_label(@search.type)}
            </div>
            <div class="w-[11%] border rounded bg-gray-200 border-gray-400 px-2 py-1">
              {gettext("Goods")}
            </div>
            <div class="w-[14%] border rounded bg-gray-200 border-gray-400 px-2 py-1">
              {gettext("Descriptions")}
            </div>
            <div class="w-[5%] border rounded bg-gray-200 border-gray-400 px-2 py-1">
              {gettext("Pack")}
            </div>
            <div class="w-[7%] border rounded bg-gray-200 border-gray-400 px-2 py-1">
              {gettext("PackQty")}
            </div>
            <div class="w-[10%] border rounded bg-gray-200 border-gray-400 px-2 py-1">
              {gettext("Qty (Avg Qty)")}
            </div>
            <div class="w-[5%] border rounded bg-gray-200 border-gray-400 px-2 py-1">
              {gettext("Unit")}
            </div>
            <div class="w-[9%] border rounded bg-gray-200 border-gray-400 px-2 py-1">
              {gettext("Avg Price")}
            </div>
            <div class="w-[10%] border rounded bg-gray-200 border-gray-400 px-2 py-1">
              {gettext("Amount")}
            </div>
          </div>

          <div id="report-lines">
            <%= for obj <- objects do %>
              <div class="flex flex-row text-center tracking-tighter">
                <div class="w-[7%] border rounded bg-blue-200 border-blue-400 px-2 py-1">
                  {obj.doc_date |> FullCircleWeb.Helpers.format_date()}
                </div>
                <div class="w-[7%] border rounded bg-blue-200 border-blue-400 px-2 py-1">
                  <.doc_link current_company={@current_company} doc_obj={obj} />
                </div>
                <div class="w-[15%] border rounded bg-blue-200 border-blue-400 px-2 py-1">
                  {obj.contact}
                </div>
                <div class="w-[11%] border rounded bg-blue-200 border-blue-400 px-2 py-1">
                  {obj.good}
                </div>
                <div
                  class="w-[14%] border rounded bg-blue-200 border-blue-400 px-2 py-1 truncate"
                  title={obj.descriptions}
                >
                  {obj.descriptions}
                </div>
                <div class="w-[5%] border rounded bg-blue-200 border-blue-400 px-2 py-1">
                  {obj.pack_name}
                </div>
                <div class="w-[7%] border rounded bg-blue-200 border-blue-400 px-2 py-1">
                  {obj.pack_qty |> Number.Delimit.number_to_delimited()}
                </div>
                <div class="w-[10%] border rounded bg-blue-200 border-blue-400 px-2 py-1">
                  {obj.qty |> Number.Delimit.number_to_delimited()} ({obj.avg_qty
                  |> Number.Delimit.number_to_delimited()})
                </div>
                <div class="w-[5%] border rounded bg-blue-200 border-blue-400 px-2 py-1">
                  {obj.unit}
                </div>
                <div class="w-[9%] border rounded bg-blue-200 border-blue-400 px-2 py-1">
                  {obj.price |> Number.Delimit.number_to_delimited()}
                </div>
                <div class="w-[10%] border rounded bg-blue-200 border-blue-400 px-2 py-1">
                  {obj.amount |> Number.Delimit.number_to_delimited()}
                </div>
              </div>
            <% end %>
          </div>

          <div id="report-summaries">
            <%= for obj <- summaries do %>
              <div class="flex flex-row text-center tracking-tighter font-bold">
                <div class="w-[29%] border rounded bg-green-200 border-green-400 px-2 py-1 text-right">
                  {gettext("Summary")}
                </div>
                <div class="w-[11%] border rounded bg-green-200 border-green-400 px-2 py-1">
                  {obj.good}
                </div>
                <div class="w-[14%] border rounded bg-green-200 border-green-400 px-2 py-1"></div>
                <div class="w-[5%] border rounded bg-green-200 border-green-400 px-2 py-1">
                  {obj.pack_name}
                </div>
                <div class="w-[7%] border rounded bg-green-200 border-green-400 px-2 py-1">
                  {obj.pack_qty |> Number.Delimit.number_to_delimited()}
                </div>
                <div class="w-[10%] border rounded bg-green-200 border-green-400 px-2 py-1">
                  {obj.qty |> Number.Delimit.number_to_delimited()} ({obj.avg_qty
                  |> Number.Delimit.number_to_delimited()})
                </div>
                <div class="w-[5%] border rounded bg-green-200 border-green-400 px-2 py-1">
                  {obj.unit}
                </div>
                <div class="w-[9%] border rounded bg-green-200 border-green-400 px-2 py-1">
                  {obj.price |> Number.Delimit.number_to_delimited()}
                </div>
                <div class="w-[10%] border rounded bg-green-200 border-green-400 px-2 py-1">
                  {obj.amount |> Number.Delimit.number_to_delimited()}
                </div>
              </div>
            <% end %>
          </div>
        </:result_html>
      </.async_html>
    </div>
    """
  end
end
