defmodule FullCircleWeb.EmployeeLive.Print do
  use FullCircleWeb, :live_view

  import FullCircleWeb.Helpers
  alias QRCode.QR
  alias FullCircle.HR

  @impl true
  def mount(%{"ids" => ids, "pre_print" => pre_print}, _session, socket) do
    detail_body_height = 290
    detail_height = 55
    chunk = (detail_body_height / detail_height) |> floor

    svg_settings = %QRCode.Render.SvgSettings{scale: 4}

    emps =
      HR.get_print_employees!(
        String.split(ids, ","),
        socket.assigns.current_company,
        socket.assigns.current_user
      )
      |> Enum.map(fn emp ->
        emp
        |> Map.merge(%{
          svg: QRCode.create(emp.id, :high) |> QRCode.render(:svg, svg_settings) |> elem(1)
        })
      end)
      |> Enum.chunk_every(2)

    {:ok,
     socket
     |> assign(:detail_body_height, detail_body_height)
     |> assign(:detail_height, detail_height)
     |> assign(:chunk_number, Enum.chunk_every(emps, chunk) |> Enum.count())
     |> assign(:detail_chunks, Enum.chunk_every(emps, chunk))
     |> assign(:emps, emps)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="print-me" class="print-here">
      <%= style(assigns) %>
      <%= Enum.map 1..@chunk_number, fn n -> %>
        <div class="page">
          <div class="details-body is-size-6">
            <%= for emp <- Enum.at(@detail_chunks, n - 1) do %>
              <div class="detail">
                <%= for e <- emp do %>
                  <div class="emp-card">
                    <div class="emp-svg"><%= e.svg |> raw %></div>
                    <div class="emp-info"><%= e.name %></div>
                    <div class="emp-info"><%= e.id_no %></div>
                  </div>
                <% end %>
              </div>
            <% end %>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  defp style(assigns) do
    ~H"""
    <style>
      .details-body { height: <%= @detail_body_height %>mm; }
      .detail { display: flex; height: <%= @detail_height %>mm; margin-bottom: 3mm; }
      .page { width: 210mm; min-height: 290mm; padding: 5mm; }

      @media print {
        @page { size: A4; margin: 0mm; }
        body { width: 210mm; height: 290mm; margin: 0mm; }
        html { margin: 0mm; }
        .page { padding: 5mm; page-break-after: always;} }

      .emp-card { width: 85mm; border: 1px solid black; margin-left: 12mm;}
      .emp-svg { margin-top: 2mm; margin-left: 20mm; }
      .emp-info { text-align: center; }
    </style>
    """
  end
end
