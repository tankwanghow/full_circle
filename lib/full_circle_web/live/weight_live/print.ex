defmodule FullCircleWeb.WeighingLive.Print do
  use FullCircleWeb, :live_view

  import FullCircleWeb.Helpers
  alias FullCircle.WeightBridge

  @impl true
  def mount(%{"id" => id, "pre_print" => pre_print}, _session, socket) do
    ids = [id]

    {:ok,
     socket
     |> assign(page_title: gettext("Print"))
     |> assign(:pre_print, pre_print)
     |> set_page_defaults()
     |> fill_journals(ids)}
  end

  @impl true
  def mount(%{"ids" => ids, "pre_print" => pre_print}, _, socket) do
    ids = String.split(ids, ",")

    {:ok,
     socket
     |> assign(page_title: gettext("Print"))
     |> assign(:pre_print, pre_print)
     |> set_page_defaults()
     |> fill_journals(ids)}
  end

  defp set_page_defaults(socket) do
    socket
    |> assign(:detail_body_height, 7)
    |> assign(:detail_height, 7)
    |> assign(:company, FullCircle.Sys.get_company!(socket.assigns.current_company.id))
  end

  defp fill_journals(socket, ids) do
    chunk = (socket.assigns.detail_body_height / socket.assigns.detail_height) |> floor

    weis =
      WeightBridge.get_print_weighings!(
        ids,
        socket.assigns.current_company,
        socket.assigns.current_user
      )
      |> Enum.map(fn wei ->
        wei
        |> Map.merge(%{
          chunk_number: Enum.chunk_every([wei], chunk) |> Enum.count()
        })
        |> Map.merge(%{
          detail_chunks: Enum.chunk_every([wei], chunk)
        })
      end)

    socket
    |> assign(:weis, weis)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="print-me" class="print-here">
      {pre_print_style(assigns)}
      {if(@pre_print == "false", do: full_style(assigns))}
      <%= for wei <- @weis do %>
        <%= Enum.map 1..wei.chunk_number, fn n -> %>
          <div class="page">
            <div class="letter-head">
              {if(@pre_print == "true", do: "", else: letter_head_data(assigns))}
            </div>
            <div class="doctype is-size-4 has-text-weight-semibold">Weighting Note</div>
            {header(wei, assigns)}
            {detail_header(assigns)}
            <div class="details-body is-size-6">
              <%= for chq <- Enum.at(wei.detail_chunks, n - 1) do %>
                {detail(chq, assigns)}
              <% end %>
            </div>
            {if(n == wei.chunk_number,
              do: footer(wei, n, wei.chunk_number, assigns),
              else: footer("continue", n, wei.chunk_number, assigns)
            )}
            {if(@pre_print == "true", do: "", else: letter_foot(wei, assigns))}
          </div>
        <% end %>
      <% end %>
    </div>
    """
  end

  def detail(wei, assigns) do
    assigns = assign(assigns, :wei, wei)

    ~H"""
    <div class="is-size-5 font-mono">
      <span class="weight"><span class="has-text-weight-semibold">Gross: </span>
        {Number.Delimit.number_to_delimited(@wei.gross, precision: 0)}</span>
      <span class="weight"><span class="has-text-weight-semibold">Tare:</span>
        {Number.Delimit.number_to_delimited(@wei.tare, precision: 0)}</span>
      <span class="weight"><span class="has-text-weight-semibold">Nett:</span>
        {Number.Delimit.number_to_delimited(@wei.gross - @wei.tare, precision: 0)}</span>
    </div>
    """
  end

  def footer("continue", page, pages, assigns) do
    assigns = assign(assigns, :page, page) |> assign(:pages, pages)

    ~H"""
    <div class="footer">
      <div class="descriptions">....continue....</div>
    </div>
    <%!-- <span class="page-count"><%= "page #{@page} of #{@pages}" %></span> --%>
    """
  end

  def footer(wei, page, pages, assigns) do
    assigns = assign(assigns, :page, page) |> assign(:pages, pages) |> assign(:wei, wei)

    ~H"""
    <div class="footer">
      <div class="empty-footer" />
    </div>
    <%!-- <span class="page-count"><%= "page #{@page} of #{@pages}" %></span> --%>
    """
  end

  def letter_foot(wei, assigns) do
    assigns = assigns |> assign(:wei, wei)

    ~H"""
    <div class="letter-foot">
      <div class="sign">Entry By {@wei.issued_by.user.email}</div>
    </div>
    """
  end

  def detail_header(assigns) do
    ~H"""
    <div class="details-header"></div>
    """
  end

  def header(wei, assigns) do
    assigns = assigns |> assign(:wei, wei)

    ~H"""
    <div class="wei-header font-mono is-size-6">
      <div class="customer">
        <div>
          Weight Date: <span class="has-text-weight-semibold">{format_date(@wei.note_date)}</span>
        </div>
        <div>
          Vehicle No: <span class="has-text-weight-semibold">{@wei.vehicle_no}</span>
        </div>
        <div>
          Goods: <span class="has-text-weight-semibold">{@wei.good_name}</span>
        </div>
        <div class="is-size-6">
          Note: <span class="has-text-weight-semibold">{@wei.note}</span>
        </div>
      </div>
      <div class="wei-info">
        <div>
          Weight Code: <span class="has-text-weight-semibold">{@wei.note_no}</span>
        </div>
        <div>
          In Time:
          <span class="has-text-weight-semibold">
            {@wei.inserted_at |> format_datetime(@company)}
          </span>
        </div>
        <div>
          Out Time:
          <span class="has-text-weight-semibold">
            {@wei.updated_at |> format_datetime(@company)}
          </span>
        </div>
      </div>
    </div>
    """
  end

  def letter_head_data(assigns) do
    ~H"""
    <div class="is-size-3 has-text-weight-bold">{@company.name}</div>
    <div>{@company.address1}, {@company.address2}</div>
    <div>
      {Enum.join([@company.zipcode, @company.city, @company.state, @company.country], ", ")}
    </div>
    <div>
      Tel: {@company.tel} RegNo: {@company.reg_no} Email: {@company.email}
    </div>
    """
  end

  def full_style(assigns) do
    ~H"""
    <style>
      .letter-head { border-bottom: 0.5mm solid black; }
      .letter-foot { border-top: 0.5mm solid black; }
      .header { border-bottom: 0.5mm solid black; }
      .footer {  }
      .terms { height: 10mm; }
      .sign { padding: 3mm; border-top: 2px dotted black; width: 40%; text-align: center; float: right; margin-left: 2mm; margin-top: 20mm;}
    </style>
    """
  end

  def pre_print_style(assigns) do
    ~H"""
    <style>
      .details-body { height: <%= @detail_body_height %>mm; }
      .detail { display: flex; height: <%= @detail_height %>mm; vertical-align: middle; text-align : center;}
      .page { width: 210mm; min-height: 115mm; padding: 5mm; }

      @media print {
        @page { size: A5; margin: 0mm; }
        body { width: 210mm; height: 115mm; margin: 0mm; }
        html { margin: 0mm; }
        .page { padding: 5mm; page-break-after: always; } }

      .letter-head { padding-bottom: 2mm; margin-bottom: 2mm; height: 28mm;}
      .doctype { float: right; margin-top: -20mm; margin-right: 0mm; }
      .wei-info, .amount { float: right; }
      .wei-header { width: 100%; height: 25mm; border-bottom: 0.5mm solid black; }
      .customer { width: 60%; padding-left: 2mm; float: left;}
      .wei-info div { margin-bottom: 0.5mm; text-align: right; }
      .details-header { margin-bottom: 5mm; }
      .weight { margin-left: 19mm; }

      .footer { margin-bottom: 1mm; padding: 1mm 0 1mm 0; }

      .empty-footer { min-height: 5px; }
      .page-count { float: right; padding-top: 5px;}
    </style>
    """
  end
end
