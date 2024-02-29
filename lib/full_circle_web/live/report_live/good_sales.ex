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
    f_date = params["f_date"] || ""
    t_date = params["t_date"] || ""

    {:noreply,
     socket
     |> assign(search: %{contact: contact, goods: goods, f_date: f_date, t_date: t_date})
     |> filter_transactions(contact, goods, f_date, t_date)}
  end

  @impl true
  def handle_event(
        "query",
        %{
          "search" => %{
            "contact" => contact,
            "goods" => goods,
            "f_date" => f_date,
            "t_date" => t_date
          }
        },
        socket
      ) do
    qry = %{
      "search[contact]" => contact,
      "search[goods]" => goods,
      "search[f_date]" => f_date,
      "search[t_date]" => t_date
    }

    url =
      "/companies/#{socket.assigns.current_company.id}/good_sales?#{URI.encode_query(qry)}"

    {:noreply,
     socket
     |> push_navigate(to: url)}
  end

  defp filter_transactions(socket, contact, goods, f_date, t_date) do
    # {objects, summaries} =
    #   if f_date == "" or t_date == "" do
    #     {[], []}
    #   else
    #     {FullCircle.TaggedBill.goods_sales_report(
    #        contact,
    #        goods,
    #        f_date,
    #        t_date,
    #        socket.assigns.current_company.id
    #      ),
    #      FullCircle.TaggedBill.goods_sales_summary_report(
    #        contact,
    #        goods,
    #        f_date,
    #        t_date,
    #        socket.assigns.current_company.id
    #      )}
    #   end

    # socket
    # |> assign(objects: objects)
    # |> assign(summaries: summaries)
    # |> assign(objects_count: Enum.count(objects))

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
                  socket.assigns.current_company.id
                ),
                FullCircle.TaggedBill.goods_sales_summary_report(
                  contact,
                  goods,
                  f_date,
                  t_date,
                  socket.assigns.current_company.id
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
      <p class="text-2xl text-center font-medium"><%= "#{@page_title}" %></p>
      <div class="border rounded bg-purple-200 text-center p-2">
        <.form for={%{}} id="search-form" phx-submit="query" autocomplete="off">
          <div class="flex tracking-tighter">
            <div class="w-[20%]">
              <.input
                label={gettext("Contact")}
                id="search_contact"
                name="search[contact]"
                value={@search.contact}
                phx-hook="tributeAutoComplete"
                url={"/api/companies/#{@current_company.id}/#{@current_user.id}/autocomplete?schema=contact&name="}
              />
            </div>
            <div class="w-[59%]">
              <.input
                label={gettext("Good List")}
                id="search_goods"
                name="search[goods]"
                value={@search.goods}
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
            <div class="w-[5%] mt-5">
              <.button>
                <%= gettext("Query") %>
              </.button>
            </div>
          </div>
        </.form>
      </div>

      <.async_html result={@result}>
        <:result_html>
          <% {objects, summaries} = @result.result %>
          <div class="font-medium flex flex-row text-center tracking-tighter mb-1">
            <div class="w-[8%] border rounded bg-gray-200 border-gray-400 px-2 py-1">
              <%= gettext("Date") %>
            </div>
            <div class="w-[8%] border rounded bg-gray-200 border-gray-400 px-2 py-1">
              <%= gettext("Doc No") %>
            </div>
            <div class="w-[25%] border rounded bg-gray-200 border-gray-400 px-2 py-1">
              <%= gettext("Customer") %>
            </div>
            <div class="w-[15%] border rounded bg-gray-200 border-gray-400 px-2 py-1">
              <%= gettext("Goods") %>
            </div>
            <div class="w-[6%] border rounded bg-gray-200 border-gray-400 px-2 py-1">
              <%= gettext("Pack") %>
            </div>
            <div class="w-[8%] border rounded bg-gray-200 border-gray-400 px-2 py-1">
              <%= gettext("PackQty") %>
            </div>
            <div class="w-[10%] border rounded bg-gray-200 border-gray-400 px-2 py-1">
              <%= gettext("Qty (Avg Qty)") %>
            </div>
            <div class="w-[6%] border rounded bg-gray-200 border-gray-400 px-2 py-1">
              <%= gettext("Unit") %>
            </div>
            <div class="w-[6%] border rounded bg-gray-200 border-gray-400 px-2 py-1">
              <%= gettext("Avg Price") %>
            </div>
            <div class="w-[8%] border rounded bg-gray-200 border-gray-400 px-2 py-1">
              <%= gettext("Amount") %>
            </div>
          </div>

          <div id="objexts">
            <%= for obj <- objects do %>
              <div class="flex flex-row text-center tracking-tighter">
                <div class="w-[8%] border rounded bg-blue-200 border-blue-400 px-2 py-1">
                  <%= obj.doc_date |> FullCircleWeb.Helpers.format_date() %>
                </div>
                <div class="w-[8%] border rounded bg-blue-200 border-blue-400 px-2 py-1">
                  <.doc_link current_company={@current_company} doc_obj={obj} />
                </div>
                <div class="w-[25%] border rounded bg-blue-200 border-blue-400 px-2 py-1">
                  <%= obj.contact %>
                </div>
                <div class="w-[15%] border rounded bg-blue-200 border-blue-400 px-2 py-1">
                  <%= obj.good %>
                </div>
                <div class="w-[6%] border rounded bg-blue-200 border-blue-400 px-2 py-1">
                  <%= obj.pack_name %>
                </div>
                <div class="w-[8%] border rounded bg-blue-200 border-blue-400 px-2 py-1">
                  <%= obj.pack_qty |> Number.Delimit.number_to_delimited() %>
                </div>
                <div class="w-[10%] border rounded bg-blue-200 border-blue-400 px-2 py-1">
                  <%= obj.qty |> Number.Delimit.number_to_delimited() %> (<%= obj.avg_qty
                  |> Number.Delimit.number_to_delimited() %>)
                </div>
                <div class="w-[6%] border rounded bg-blue-200 border-blue-400 px-2 py-1">
                  <%= obj.unit %>
                </div>
                <div class="w-[6%] border rounded bg-blue-200 border-blue-400 px-2 py-1">
                  <%= obj.price |> Number.Delimit.number_to_delimited() %>
                </div>
                <div class="w-[8%] border rounded bg-blue-200 border-blue-400 px-2 py-1">
                  <%= obj.amount |> Number.Delimit.number_to_delimited() %>
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
                  <%= obj.good %>
                </div>
                <div class="w-[6%] border rounded bg-green-200 border-green-400 px-2 py-1">
                  <%= obj.pack_name %>
                </div>
                <div class="w-[8%] border rounded bg-green-200 border-green-400 px-2 py-1">
                  <%= obj.pack_qty |> Number.Delimit.number_to_delimited() %>
                </div>
                <div class="w-[10%] border rounded bg-green-200 border-green-400 px-2 py-1">
                  <%= obj.qty |> Number.Delimit.number_to_delimited() %> (<%= obj.avg_qty
                  |> Number.Delimit.number_to_delimited() %>)
                </div>
                <div class="w-[6%] border rounded bg-green-200 border-green-400 px-2 py-1">
                  <%= obj.unit %>
                </div>
                <div class="w-[6%] border rounded bg-green-200 border-green-400 px-2 py-1">
                  <%= obj.price |> Number.Delimit.number_to_delimited() %>
                </div>
                <div class="w-[8%] border rounded bg-green-200 border-green-400 px-2 py-1">
                  <%= obj.amount |> Number.Delimit.number_to_delimited() %>
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
