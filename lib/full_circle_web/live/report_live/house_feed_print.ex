defmodule FullCircleWeb.ReportLive.HouseFeedPrint do
  use FullCircleWeb, :live_view

  @impl true
  def mount(params, _session, socket) do
    detail_body_height = 190
    detail_height = 6
    chunk = (detail_body_height / detail_height) |> floor

    {cols, rows} =
      fill_data(socket, params["report"], params["fdate"], params["tdate"])

    {:ok,
     socket
     |> assign(:detail_body_height, detail_body_height)
     |> assign(:detail_height, detail_height)
     |> assign(:detail_chunks, Enum.chunk_every(rows, chunk))
     |> assign(:cols, cols)
     |> assign(:rows, rows)
     |> assign(page_title: gettext("Print"))
     |> assign(:fdate, Date.from_iso8601!(params["fdate"]))
     |> assign(:tdate, Date.from_iso8601!(params["tdate"]))}
  end

  defp fill_data(socket, _name, fdate, tdate) do
    FullCircle.Layer.house_feed_type(
      fdate,
      tdate,
      socket.assigns.current_company.id
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="print-me" class="print-here">
      <%= style(assigns) %>

      <%= for chunk <- @detail_chunks do %>
        <div class="page">
          <%= headers(assigns) %>
          <%= for r <- chunk do %>
            <%= details(assigns, r) %>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  defp details(assigns, row) do
    ~H"""
    <div class="details">
      <%= for c <- row do %>
        <div class="detail">
          <%= c || "NO" %>
        </div>
      <% end %>
    </div>
    """
  end

  defp headers(assigns) do
    ~H"""
    <div :if={Enum.count(@cols) > 0} class="headers">
      <%= for h <- @cols do %>
        <div class="header">
          <%= h %>
        </div>
      <% end %>
    </div>
    """
  end

  defp style(assigns) do
    ~H"""
    <style>
      .detail { height: <%= @detail_height %>mm; vertical-align: middle; }
      .page { width: 290mm; min-height: 210mm; padding: 5mm; }

      @media print {
        @page { size: A4 landscape; margin: 0mm; }
        body { width: 290mm; height: 210mm; margin: 0mm; }
        html { margin: 0mm; }
        .page { padding-left: 5mm; padding-top: 0mm; } }

      .headers { display: flex; text-align: center; font-weight: bold;}
      .details { display: flex; text-align: center; }
      .headers .header { width: 4%; border: 1px solid gray; }
      .details .detail { width: 4%; border: 1px solid gray; }
    </style>
    """
  end
end
