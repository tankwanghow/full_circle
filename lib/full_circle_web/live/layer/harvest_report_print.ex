defmodule FullCircleWeb.LayerLive.HarvestReportPrint do
  use FullCircleWeb, :live_view

  @impl true
  def mount(params, _session, socket) do
    detail_body_height = 258.5
    detail_height = 5.5
    chunk = (detail_body_height / detail_height) |> floor

    {tdate, data} =
      fill_data(socket, params["tdate"])

    {:ok,
     socket
     |> assign(:detail_body_height, detail_body_height)
     |> assign(:detail_height, detail_height)
     |> assign(:chunk_number, Enum.chunk_every(data, chunk) |> Enum.count())
     |> assign(:detail_chunks, Enum.chunk_every(data, chunk))
     |> assign(:tdate, tdate)
     |> assign(:data, data)
     |> assign(page_title: gettext("Print"))}
  end

  defp fill_data(socket, tdate) do
    tdate = tdate |> Timex.parse!("{YYYY}-{0M}-{0D}") |> NaiveDateTime.to_date()

    data =
      FullCircle.Layer.harvest_report(
        tdate,
        socket.assigns.current_company.id
      )

    {tdate, data}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="print-me" class="print-here">
      <%= style(assigns) %>
      <%= Enum.map 1..@chunk_number, fn n -> %>
        <div class="page">
          <span class="header is-size-5">Harvest Report :- </span>
          <span class="header is-size-5 has-text-weight-bold"><%= @tdate %></span>
          <div class="page-count"><%= "page #{n} of #{@chunk_number}" %></div>
          <div class="details-body is-size-6">
            <div class="details-header has-text-weight-bold">
              <span class="house">Hou</span>
              <span class="collector">Collector</span>
              <span class="age">Age</span>
              <span class="prod">Prod</span>
              <span class="death">Dea</span>
              <span class="yield">Yld 0</span>
              <span class="yield">Yld 1</span>
              <span class="yield">Yld 2</span>
              <span class="yield">Yld 3</span>
              <span class="yield">Yld 4</span>
              <span class="yield">Yld 5</span>
              <span class="yield">Yld 6</span>
              <span class="yield">Yld 7</span>
            </div>
            <%= for dat <- Enum.at(@detail_chunks, n - 1) do %>
              <%= har_detail(dat, assigns) %>
            <% end %>
            <div class="nofooter" />
          </div>
          <%= footer(n, assigns) %>
        </div>
      <% end %>
    </div>
    """
  end

  defp footer(n, assigns) do
    assigns = assign(assigns, :n, n)

    ~H"""
    <%= if @n == @chunk_number do %>
      <div class="footer has-text-weight-bold">
        <span>
          Avg Age: <%= ((@data |> Enum.reduce(0, fn e, acc -> acc + e.age end)) / Enum.count(@data))
          |> trunc %>
        </span>
        <span>
          Total Production: <%= ((@data |> Enum.reduce(0, fn e, acc -> acc + e.prod end)) / 30)
          |> trunc %>
        </span>
        <span>
          Total Death: <%= @data |> Enum.reduce(0, fn e, acc -> acc + e.dea end) |> trunc %>
        </span>
      </div>
    <% end %>
    """
  end

  defp yield_bold(y1, y2) do
    cond do
      y1 - y2 > -0.02 -> ""
      y1 - y2 <= -0.02 -> "has-text-weight-bold"
    end
  end

  defp har_detail(dtl, assigns) do
    assigns = assign(assigns, :dtl, dtl)

    ~H"""
    <div class="detail has-text-weight-light">
      <span class="house">
        <%= @dtl.house_no %>
      </span>
      <span class="collector">
        <%= (@dtl.employee || "Company") |> String.slice(0, 15) %>
      </span>
      <span class="age">
        <%= @dtl.age %>
      </span>
      <span class="prod">
        <%= (@dtl.prod / 30) |> trunc %>
      </span>
      <span class="death">
        <%= @dtl.dea %>
      </span>
      <span class={["yield", yield_bold(@dtl.yield_0, @dtl.yield_1)]}>
        <%= (@dtl.yield_0 * 100) |> Number.Percentage.number_to_percentage(precision: 0) %>
      </span>
      <span class={["yield", yield_bold(@dtl.yield_1, @dtl.yield_2)]}>
        <%= (@dtl.yield_1 * 100) |> Number.Percentage.number_to_percentage(precision: 0) %>
      </span>
      <span class={["yield", yield_bold(@dtl.yield_2, @dtl.yield_3)]}>
        <%= (@dtl.yield_2 * 100) |> Number.Percentage.number_to_percentage(precision: 0) %>
      </span>
      <span class={["yield", yield_bold(@dtl.yield_3, @dtl.yield_4)]}>
        <%= (@dtl.yield_3 * 100) |> Number.Percentage.number_to_percentage(precision: 0) %>
      </span>
      <span class={["yield", yield_bold(@dtl.yield_4, @dtl.yield_5)]}>
        <%= (@dtl.yield_4 * 100) |> Number.Percentage.number_to_percentage(precision: 0) %>
      </span>
      <span class={["yield", yield_bold(@dtl.yield_5, @dtl.yield_6)]}>
        <%= (@dtl.yield_5 * 100) |> Number.Percentage.number_to_percentage(precision: 0) %>
      </span>
      <span class={["yield", yield_bold(@dtl.yield_6, @dtl.yield_7)]}>
        <%= (@dtl.yield_6 * 100) |> Number.Percentage.number_to_percentage(precision: 0) %>
      </span>
      <span class="yield">
        <%= (@dtl.yield_7 * 100) |> Number.Percentage.number_to_percentage(precision: 0) %>
      </span>
    </div>
    """
  end

  defp style(assigns) do
    ~H"""
    <style>
      .details-body { height: <%= @detail_body_height %>mm; }
      .detail { display: flex; height: <%= @detail_height %>mm; vertical-align: middle; align-items : center; }
      .page { width: 210mm; min-height: 290mm; padding: 5mm; }

      @media print {
        @page { size: A4; margin: 0mm; }
        body { width: 210mm; height: 290mm; margin: 0mm; }
        html { margin: 0mm; }
        .page { padding: 5mm; page-break-after: always;} }

      .header { padding-bottom: 2mm;  height: 10mm;}

      .details-header { display: flex; text-align: center; padding-bottom: 1mm; padding-top: 1mm; border-bottom: 1px solid black; border-top: 1px solid black;}

      .house { width: 10%; padding-right: 2mm; text-align: right; border-right: 1px solid black; border-left: 1px solid black;}
      .collector { width: 19%; text-align: center; border-right: 1px solid black;}
      .age { width: 6%; text-align: center; border-right: 1px solid black;}
      .prod { width: 7%; text-align: center; border-right: 1px solid black;}
      .death { width: 6%; text-align: center; border-right: 1px solid black;}
      .yield { width: 6.5%; text-align: center; border-right: 1px solid black;}

      .footer { display: flex; gap: 5mm; padding: 2mm; border-bottom: 1px solid black; border-top: 1px solid black; }
      .nofooter { border-top: 1px solid black; }
      .page-count { float: right; }
    </style>
    """
  end
end
