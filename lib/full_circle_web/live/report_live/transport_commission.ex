defmodule FullCircleWeb.ReportLive.TransportCommission do
  use FullCircleWeb, :live_view

  alias FullCircle.TaggedBill

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(page_title: "Driver Commission")

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    params = params["search"]

    tags = params["tags"] || ""
    f_date = params["f_date"] || Timex.today()
    t_date = params["t_date"] || Timex.today()

    {:noreply,
     socket
     |> assign(search: %{tags: tags, f_date: f_date, t_date: t_date})
     |> query(tags, f_date, t_date)
     |> assign(can_print: false)
     |> assign(selected: [])}
  end

  @impl true
  def handle_event(
        "query",
        %{
          "search" => %{
            "tags" => tags,
            "f_date" => f_date,
            "t_date" => t_date
          }
        },
        socket
      ) do
    qry = %{
      "search[tags]" => tags |> String.trim(),
      "search[f_date]" => f_date,
      "search[t_date]" => t_date
    }

    url =
      "/companies/#{socket.assigns.current_company.id}/transport_commission?#{URI.encode_query(qry)}"

    {:noreply,
     socket
     |> push_navigate(to: url)}
  end

  defp query(socket, tags, f_date, t_date) do
    current_company = socket.assigns.current_company

    socket
    |> assign_async(
      :result,
      fn ->
        {:ok,
         %{
           result:
             if tags == "" or f_date == "" or t_date == "" do
               []
             else
               TaggedBill.transport_commission(
                 tags,
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
    <div class="w-11/12 mx-auto mb-8">
      <p class="text-2xl text-center font-medium">{"#{@page_title}"}</p>
      <div class="border rounded bg-amber-200 text-center p-2">
        <.form for={%{}} id="search-form" phx-submit="query" autocomplete="off" class="w-9/12 mx-auto">
          <div class="grid grid-cols-12 tracking-tighter">
            <div class="col-span-6">
              <.input
                label={gettext("Tags")}
                name="search[tags]"
                id="search_tags"
                value={@search.tags}
                phx-hook="tributeTagText"
                url={"/list/companies/#{@current_company.id}/#{@current_user.id}/billingtags?klass=FullCircle.Billing.Invoice&tag_field=loader_tags&tag="}
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
                {gettext("Query")}
              </.button>
              <.link
                :if={@result.ok? and Enum.count(@result.result) > 0}
                navigate={
                  ~p"/companies/#{@current_company.id}/csv?report=tagged_bills&tags=#{@search.tags}&fdate=#{@search.f_date}&tdate=#{@search.t_date}"
                }
                target="_blank"
                class="blue button"
              >
                CSV
              </.link>
            </div>
          </div>
        </.form>

        <.async_html result={@result}>
          <:result_html>
            {FullCircleWeb.CsvHtml.headers(
              [
                gettext("Date"),
                gettext("DocNo"),
                gettext("Contact"),
                gettext("Goods"),
                gettext("Quantity"),
                gettext("Unit"),
                gettext("LTags"),
                gettext("LWTag"),
                gettext("Wages"),
                gettext("DTags"),
                gettext("DWTag"),
                gettext("Wages")
              ],
              "font-medium flex flex-row text-center tracking-tighter mb-1",
              ["6%", "7%", "13%", "18%", "7%", "5%", "8%", "9%", "5%", "8%", "9%", "5%"],
              "border rounded bg-gray-200 border-gray-400 px-2 py-1",
              assigns
            )}

            {FullCircleWeb.CsvHtml.data(
              [
                :invoice_date,
                :doc_no,
                :contact,
                :good_names,
                :quantity,
                :unit,
                :loader_tags,
                :loader_wages_tags,
                :load_wages,
                :delivery_man_tags,
                :delivery_wages_tags,
                :delivery_wages
              ],
              @result.result,
              [
                nil,
                nil,
                nil,
                nil,
                fn n -> Number.Delimit.number_to_delimited(n, precision: 2) end,
                nil,
                nil,
                nil,
                nil,
                nil,
                nil,
                nil
              ],
              "flex flex-row text-center tracking-tighter overflow-clip max-h-8",
              ["6%", "7%", "13%", "18%", "7%", "5%", "8%", "9%", "5%", "8%", "9%", "5%"],
              "border rounded bg-blue-200 border-blue-400 px-2 py-1",
              assigns
            )}
            <div class="flex h-8 font-bold">
              <div class="w-[73%] border rounded bg-green-200 border-green-400 px-2 py-1"></div>
              <div class="w-[5%] border rounded bg-green-200 border-green-400 px-2 py-1">
                {[0.0 | Enum.map(@result.result, fn x -> x.load_wages end)]
                |> Enum.sum()
                |> Float.round(2)}
              </div>
              <div class="w-[17%] border rounded bg-green-200 border-green-400 px-2 py-1"></div>
              <div class="w-[5%] border rounded bg-green-200 border-green-400 px-2 py-1">
                {[0.0 | Enum.map(@result.result, fn x -> x.delivery_wages end)]
                |> Enum.sum()
                |> Float.round(2)}
              </div>
            </div>
          </:result_html>
        </.async_html>
      </div>
    </div>
    """
  end
end
