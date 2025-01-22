defmodule FullCircleWeb.ReportLive.GoodSales do
  use FullCircleWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(page_title: "Good Sales Listing")

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    params = params["search"]

    contact = params["contact"] || ""
    goods = params["goods"] || ""
    category = params["category"] || ""
    f_date = params["f_date"] || "#{Timex.today()}"
    t_date = params["t_date"] || "#{Timex.today()}"

    {:noreply,
     socket
     |> assign(
       search: %{
         contact: contact,
         goods: goods,
         f_date: f_date,
         t_date: t_date,
         category: category
       }
     )
     |> filter_transactions(contact, goods, f_date, t_date)}
  end

  @impl true
  def handle_event(
        "query",
        %{
          "search" => %{
            "contact" => contact,
            "goods" => goods,
            "category" => category,
            "f_date" => f_date,
            "t_date" => t_date
          }
        },
        socket
      ) do
    qry = %{
      "search[contact]" => contact,
      "search[goods]" => goods,
      "search[category]" => category,
      "search[f_date]" => f_date,
      "search[t_date]" => t_date
    }

    url =
      "/companies/#{socket.assigns.current_company.id}/good_sales?#{URI.encode_query(qry)}"

    {:noreply,
     socket
     |> push_navigate(to: url)}
  end

  @impl true
  def handle_event(
        "change",
        %{
          "_target" => ["search", "category"],
          "search" => %{
            "category" => cat,
            "contact" => cont,
            "f_date" => f_date,
            "goods" => _goods,
            "t_date" => t_date
          }
        },
        socket
      ) do
    goods =
      FullCircle.Product.get_goods_by_category(
        cat,
        socket.assigns.current_company,
        socket.assigns.current_user
      )

    goods =
      if Enum.count(goods) > 0 do
        goods
        |> Enum.map_join(", ", fn x -> x.name end)
      else
        ["Not Goods in this category"]
      end

    {:noreply,
     socket
     |> assign(
       search: %{
         contact: cont,
         goods: goods,
         f_date: f_date,
         t_date: t_date,
         category: cat
       }
     )}
  end

  @impl true
  def handle_event("change", _, socket) do
    {:noreply, socket}
  end

  defp filter_transactions(socket, contact, goods, f_date, t_date) do
    current_company = socket.assigns.current_company

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
               {FullCircle.TaggedBill.goods_sales_report(
                  contact,
                  goods,
                  f_date,
                  t_date,
                  current_company.id
                ),
                FullCircle.TaggedBill.goods_sales_summary_report(
                  contact,
                  goods,
                  f_date,
                  t_date,
                  current_company.id
                )}
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
        <.form for={%{}} id="search-form" phx-change="change" phx-submit="query" autocomplete="off">
          <div class="flex tracking-tighter">
            <div class="w-[10%]">
              <.input
                id="search_category"
                name="search[category]"
                value={@search.category}
                label={gettext("Category")}
                type="select"
                options={FullCircle.Product.categories()}
              />
            </div>
            <div class="w-[40%]">
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
                  ~p"/companies/#{@current_company.id}/csv?report=goodsales&&contact=#{@search.goods}&goods=#{@search.goods}&fdate=#{@search.f_date}&tdate=#{@search.t_date}"
                }
                class="blue button"
                target="_blank"
              >
                CSV
              </.link>
            </div>
          </div>
          <div class="w-[100%]">
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
        </.form>
      </div>

      <.async_html result={@result}>
        <:result_html>
          <% {objects, summaries} = @result.result %>
          <div class="font-medium flex flex-row text-center tracking-tighter mb-1">
            <div class="w-[8%] border rounded bg-gray-200 border-gray-400 px-2 py-1">
              {gettext("Date")}
            </div>
            <div class="w-[8%] border rounded bg-gray-200 border-gray-400 px-2 py-1">
              {gettext("Doc No")}
            </div>
            <div class="w-[25%] border rounded bg-gray-200 border-gray-400 px-2 py-1">
              {gettext("Customer")}
            </div>
            <div class="w-[15%] border rounded bg-gray-200 border-gray-400 px-2 py-1">
              {gettext("Goods")}
            </div>
            <div class="w-[6%] border rounded bg-gray-200 border-gray-400 px-2 py-1">
              {gettext("Pack")}
            </div>
            <div class="w-[8%] border rounded bg-gray-200 border-gray-400 px-2 py-1">
              {gettext("PackQty")}
            </div>
            <div class="w-[10%] border rounded bg-gray-200 border-gray-400 px-2 py-1">
              {gettext("Qty (Avg Qty)")}
            </div>
            <div class="w-[6%] border rounded bg-gray-200 border-gray-400 px-2 py-1">
              {gettext("Unit")}
            </div>
            <div class="w-[6%] border rounded bg-gray-200 border-gray-400 px-2 py-1">
              {gettext("Avg Price")}
            </div>
            <div class="w-[8%] border rounded bg-gray-200 border-gray-400 px-2 py-1">
              {gettext("Amount")}
            </div>
          </div>

          <div id="objexts">
            <%= for obj <- objects do %>
              <div class="flex flex-row text-center tracking-tighter">
                <div class="w-[8%] border rounded bg-blue-200 border-blue-400 px-2 py-1">
                  {obj.doc_date |> FullCircleWeb.Helpers.format_date()}
                </div>
                <div class="w-[8%] border rounded bg-blue-200 border-blue-400 px-2 py-1">
                  <.doc_link current_company={@current_company} doc_obj={obj} />
                </div>
                <div class="w-[25%] border rounded bg-blue-200 border-blue-400 px-2 py-1">
                  {obj.contact}
                </div>
                <div class="w-[15%] border rounded bg-blue-200 border-blue-400 px-2 py-1">
                  {obj.good}
                </div>
                <div class="w-[6%] border rounded bg-blue-200 border-blue-400 px-2 py-1">
                  {obj.pack_name}
                </div>
                <div class="w-[8%] border rounded bg-blue-200 border-blue-400 px-2 py-1">
                  {obj.pack_qty |> Number.Delimit.number_to_delimited()}
                </div>
                <div class="w-[10%] border rounded bg-blue-200 border-blue-400 px-2 py-1">
                  {obj.qty |> Number.Delimit.number_to_delimited()} ({obj.avg_qty
                  |> Number.Delimit.number_to_delimited()})
                </div>
                <div class="w-[6%] border rounded bg-blue-200 border-blue-400 px-2 py-1">
                  {obj.unit}
                </div>
                <div class="w-[6%] border rounded bg-blue-200 border-blue-400 px-2 py-1">
                  {obj.price |> Number.Delimit.number_to_delimited()}
                </div>
                <div class="w-[8%] border rounded bg-blue-200 border-blue-400 px-2 py-1">
                  {obj.amount |> Number.Delimit.number_to_delimited()}
                </div>
              </div>
            <% end %>
          </div>

          <div id="objexts">
            <%= for obj <- summaries do %>
              <div class="flex flex-row text-center tracking-tighter font-bold">
                <div class="w-[41%] border rounded bg-green-200 border-green-400 px-2 py-1 text-right">
                  Summary
                </div>
                <div class="w-[15%] border rounded bg-green-200 border-green-400 px-2 py-1">
                  {obj.good}
                </div>
                <div class="w-[6%] border rounded bg-green-200 border-green-400 px-2 py-1">
                  {obj.pack_name}
                </div>
                <div class="w-[8%] border rounded bg-green-200 border-green-400 px-2 py-1">
                  {obj.pack_qty |> Number.Delimit.number_to_delimited()}
                </div>
                <div class="w-[10%] border rounded bg-green-200 border-green-400 px-2 py-1">
                  {obj.qty |> Number.Delimit.number_to_delimited()} ({obj.avg_qty
                  |> Number.Delimit.number_to_delimited()})
                </div>
                <div class="w-[6%] border rounded bg-green-200 border-green-400 px-2 py-1">
                  {obj.unit}
                </div>
                <div class="w-[6%] border rounded bg-green-200 border-green-400 px-2 py-1">
                  {obj.price |> Number.Delimit.number_to_delimited()}
                </div>
                <div class="w-[8%] border rounded bg-green-200 border-green-400 px-2 py-1">
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
