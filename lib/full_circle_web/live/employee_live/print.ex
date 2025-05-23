defmodule FullCircleWeb.EmployeeLive.Print do
  use FullCircleWeb, :live_view

  alias FullCircle.HR

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    ids = [id]
    {:ok, socket |> fill_employee(ids)}
  end

  @impl true
  def mount(%{"ids" => ids}, _session, socket) do
    ids = String.split(ids, ",")
    {:ok, socket |> fill_employee(ids)}
  end

  defp fill_employee(socket, ids) do
    detail_body_height = 285
    detail_height = 52
    chunk = (detail_body_height / detail_height) |> floor

    svg_settings = %QRCode.Render.SvgSettings{scale: 4}

    emps =
      HR.get_print_employees!(
        ids,
        socket.assigns.current_company,
        socket.assigns.current_user
      )
      |> Enum.map(fn emp ->
        emp
        |> Map.merge(%{
          svg: QRCode.create(emp.id, :high) |> QRCode.render(:svg, svg_settings) |> elem(1)
        })
      end)
      |> Enum.chunk_every(3)

    socket
    |> assign(page_title: gettext("Print"))
    |> assign(:detail_body_height, detail_body_height)
    |> assign(:detail_height, detail_height)
    |> assign(:chunk_number, Enum.chunk_every(emps, chunk) |> Enum.count())
    |> assign(:detail_chunks, Enum.chunk_every(emps, chunk))
    |> assign(:emps, emps)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="print-me" class="print-here">
      {style(assigns)}
      <%= Enum.map 1..@chunk_number, fn n -> %>
        <div class="page">
          <div class="details-body is-size-6">
            <%= for emp <- Enum.at(@detail_chunks, n - 1) do %>
              <div class="detail">
                <%= for e <- emp do %>
                  <div class="emp-card">
                    <div class="emp-svg">{e.svg |> raw}</div>
                    <div class="emp-info">{e.name}</div>
                    <div class="emp-info">{e.id_no}</div>
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

      .emp-card { width: 55mm; border: 1px solid black; margin-left: 10mm; }
      .emp-card .emp-svg { margin-left: 7.5mm; }
      .emp-card .emp-info { text-align: center; width: 55mm; max-height: 5mm; overflow: hidden; }
    </style>
    """
  end
end
