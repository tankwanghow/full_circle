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
        rows =
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

        {:ok, %{result: %{rows: rows, summary: summarize(rows)}}}
      end
    )
  end

  defp summarize(rows) do
    rows
    |> Enum.group_by(& &1.employee_tag)
    |> Enum.map(fn {tag, rs} ->
      load = rs |> Enum.map(& &1.load_wages) |> Enum.sum() |> Float.round(2)
      delivery = rs |> Enum.map(& &1.delivery_wages) |> Enum.sum() |> Float.round(2)

      %{
        employee_tag: tag,
        load_wages: load,
        delivery_wages: delivery,
        total: Float.round(load + delivery, 2)
      }
    end)
    |> Enum.sort_by(& &1.employee_tag)
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
                label={gettext("Tags (or \"All\")")}
                name="search[tags]"
                id="search_tags"
                value={@search.tags}
                placeholder={gettext("#JohnDoe #MarySmith or All")}
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
                :if={@result.ok? and Enum.count(@result.result.rows) > 0}
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
            <% %{rows: rows, summary: summary} = @result.result %>

            <div :if={Enum.any?(summary)} class="mt-2 mb-3">
              <div class="font-medium flex flex-row text-center tracking-tighter mb-1">
                <div class="w-[40%] border rounded bg-gray-300 border-gray-500 px-2 py-1">
                  {gettext("Employee")}
                </div>
                <div class="w-[20%] border rounded bg-gray-300 border-gray-500 px-2 py-1">
                  {gettext("Load Wages")}
                </div>
                <div class="w-[20%] border rounded bg-gray-300 border-gray-500 px-2 py-1">
                  {gettext("Delivery Wages")}
                </div>
                <div class="w-[20%] border rounded bg-gray-300 border-gray-500 px-2 py-1">
                  {gettext("Total")}
                </div>
              </div>
              <%= for s <- summary do %>
                <div class="flex flex-row text-center tracking-tighter">
                  <div class="w-[40%] border rounded bg-yellow-100 border-yellow-400 px-2 py-1">
                    {s.employee_tag}
                  </div>
                  <div class="w-[20%] border rounded bg-yellow-100 border-yellow-400 px-2 py-1">
                    {Number.Delimit.number_to_delimited(s.load_wages, precision: 2)}
                  </div>
                  <div class="w-[20%] border rounded bg-yellow-100 border-yellow-400 px-2 py-1">
                    {Number.Delimit.number_to_delimited(s.delivery_wages, precision: 2)}
                  </div>
                  <div class="w-[20%] font-bold border rounded bg-yellow-200 border-yellow-500 px-2 py-1">
                    {Number.Delimit.number_to_delimited(s.total, precision: 2)}
                  </div>
                </div>
              <% end %>
              <div class="flex flex-row text-center tracking-tighter font-bold">
                <div class="w-[40%] border rounded bg-green-200 border-green-500 px-2 py-1">
                  {gettext("Total")}
                </div>
                <div class="w-[20%] border rounded bg-green-200 border-green-500 px-2 py-1">
                  {summary
                  |> Enum.map(& &1.load_wages)
                  |> Enum.sum()
                  |> Float.round(2)
                  |> Number.Delimit.number_to_delimited(precision: 2)}
                </div>
                <div class="w-[20%] border rounded bg-green-200 border-green-500 px-2 py-1">
                  {summary
                  |> Enum.map(& &1.delivery_wages)
                  |> Enum.sum()
                  |> Float.round(2)
                  |> Number.Delimit.number_to_delimited(precision: 2)}
                </div>
                <div class="w-[20%] border rounded bg-green-200 border-green-500 px-2 py-1">
                  {summary
                  |> Enum.map(& &1.total)
                  |> Enum.sum()
                  |> Float.round(2)
                  |> Number.Delimit.number_to_delimited(precision: 2)}
                </div>
              </div>
            </div>

            {FullCircleWeb.CsvHtml.headers(
              [
                gettext("Employee"),
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
              ["6%", "6%", "7%", "12%", "16%", "6%", "5%", "8%", "8%", "5%", "8%", "8%", "5%"],
              "border rounded bg-gray-200 border-gray-400 px-2 py-1",
              assigns
            )}

            {FullCircleWeb.CsvHtml.data(
              [
                :employee_tag,
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
              rows,
              [
                nil,
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
              ["6%", "6%", "7%", "12%", "16%", "6%", "5%", "8%", "8%", "5%", "8%", "8%", "5%"],
              "border rounded bg-blue-200 border-blue-400 px-2 py-1",
              assigns
            )}
          </:result_html>
        </.async_html>
      </div>
    </div>
    """
  end
end
