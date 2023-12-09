defmodule FullCircleWeb.LayerLive.HarvestWageReportPrint do
  use FullCircleWeb, :live_view

  @impl true
  def mount(params, _session, socket) do
    {_, _, data, raw_data} =
      fill_data(socket, params["fdate"], params["tdate"])

    {:ok,
     socket
     |> assign(:data, data)
     |> assign(:raw_data, raw_data)
     |> assign(page_title: gettext("Print"))}
  end

  def fill_data(socket, fdate, tdate) do
    fdate = fdate |> Timex.parse!("{YYYY}-{0M}-{0D}") |> NaiveDateTime.to_date()
    tdate = tdate |> Timex.parse!("{YYYY}-{0M}-{0D}") |> NaiveDateTime.to_date()

    raw_data =
      FullCircle.Layer.harvest_wage_report(
        fdate,
        tdate,
        socket.assigns.current_company.id
      )

    data =
      Enum.group_by(
        raw_data,
        & &1.employee,
        &%{har_date: &1.har_date, house: &1.house_no, prod: &1.prod, wages: &1.wages}
      )
      |> Enum.map(fn {n, l} ->
        {n, Enum.group_by(l, & &1.har_date, &%{house: &1.house, prod: &1.prod, wages: &1.wages})}
      end)

    {fdate, tdate, data, raw_data}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="print-me" class="print-here">
      <%= style(assigns) %>
      <%= for {emp, har_list} <- @data do %>
        <div class="page">
          <span class="has-text-weight-bold is-size-5"><%= emp %></span>
          <%= for {d, l} <- har_list do %>
            <div class="wages">
              <div class="info date">
                <span><%= FullCircleWeb.Helpers.format_date(d) %></span>
              </div>
              <%= for v <- l do %>
                <div class="info">
                  <span>
                    <span class="is-italic"><%= v.house %></span>
                    &#8226; <span><%= v.prod %></span>
                    &#8226;
                    <span class="has-text-weight-medium">
                      <%= Number.Delimit.number_to_delimited(v.wages, precision: 2) %>
                    </span>
                  </span>
                </div>
              <% end %>
              <div class="info total">
                <span class="tot has-text-weight-semibold">Wages</span>
                <span class="amt">
                  <%= Enum.reduce(l, 0, fn x, acc -> acc + Decimal.to_float(x.wages) end)
                  |> Number.Delimit.number_to_delimited(precision: 2) %>
                </span>
              </div>
            </div>
          <% end %>
          <div class="emp_total_wages">
            Wages for <%= emp %>: <%= Enum.filter(@raw_data, fn e -> e.employee == emp end)
            |> Enum.reduce(0, fn e, acc -> acc + Decimal.to_float(e.wages) end)
            |> Number.Delimit.number_to_delimited(precision: 2) %>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  defp style(assigns) do
    ~H"""
    <style>
      .page { width: 210mm; min-height: 290mm; padding: 5mm; }

      @media print {
        @page { size: A4; margin: 0mm; }
        body { width: 210mm; height: 290mm; margin: 0mm; }
        html { margin: 0mm; }
        .page { padding: 5mm; page-break-after: always;} }

      .wages { display: grid; gap: 1mm; padding: 1mm; grid-template-columns: repeat(12, minmax(0, 1fr)); text-align: center; }

      .wages .info {
        grid-column: span 2 / span 12;
        display: grid; grid-template-columns: repeat(12, minmax(0, 1fr));
        border: 1px solid gray;
      }

      .wages .info.date span {
        grid-column: span 12 / span 12;
      }

      .wages .info span {
        grid-column: span 12 / span 12;
      }

      .wages .info .tot {
        grid-column: span 6 / span 12;
      }

      .wages .info .amt {
        grid-column: span 6 / span 12;
      }

      .emp_total_wages {
        text-align: center;
        font: bold 1.5rem sans-serif;
        margin-left: auto;
        margin-right: auto;
        border: 3px double black;
      }
    </style>
    """
  end
end
