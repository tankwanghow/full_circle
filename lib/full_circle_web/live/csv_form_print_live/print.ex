defmodule FullCircleWeb.CsvFormPrintLive.Print do
  use FullCircleWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    detail_body_height = 200
    detail_height = 44
    chunk = (detail_body_height / detail_height) |> floor

    data =
      fill_data()
      |> Enum.filter(fn x -> x.debit == "0.00" end)
      |> Enum.filter(fn x -> x.source != "Bank Transfer" end)
      |> Enum.filter(fn x -> x.relatedaccount != "404 - Bank Charges" end)

    {:ok,
     socket
     |> assign(:detail_body_height, detail_body_height)
     |> assign(:detail_height, detail_height)
     |> assign(:chunk_number, Enum.chunk_every(data, chunk) |> Enum.count())
     |> assign(:detail_chunks, Enum.chunk_every(data, chunk))
     |> assign(page_title: gettext("Print"))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="print-me" class="print-here">
      <%= style(assigns) %>
      <%= Enum.map 1..@chunk_number, fn n -> %>
        <div class="page">
          <%= for obj <- Enum.at(@detail_chunks, n - 1) do %>
            <div class="voucher">
              <div class="form-title is-size-4 has-text-weight-bold">
                Golden Husbandry Sdn. Bhd.
              </div>
              <div class="form-title is-size-5 has-text-weight-bold">Payment Voucher</div>
              <%= detail(obj, assigns) %>
            </div>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  defp detail(obj, assigns) do
    assigns = assign(assigns, :obj, obj)

    ~H"""
    <div class="detail">
      <div class="date is-size-5">
        <span class="has-text-weight-semibold">Date : </span><%= @obj.date %>
      </div>

      <div class="is-size-5">
        <span class="has-text-weight-semibold">Debit : </span><%= @obj.relatedaccount %>
      </div>

      <div class="is-size-5">
        <span class="has-text-weight-semibold">Pay To : </span><%= @obj.contact %>
      </div>

      <div class="is-size-5">
        <span class="has-text-weight-semibold">Description : </span><%= "#{@obj.description}, #{@obj.reference} " %>
      </div>

      <div class="amount is-size-4">
        <span class="has-text-weight-semibold">Amount : </span><%= @obj.credit %>
      </div>

      <div class="credit is-size-5">
        <span class="has-text-weight-semibold">Credit : </span><%= @obj.from %>
      </div>
    </div>
    """
  end

  def fill_data() do
    File.stream!(
      "/home/tankwanghow/Documents/Golden Husbandry/Draft Account 2023/ghbanktrans2023.csv"
    )
    |> NimbleCSV.RFC4180.parse_stream(skip_headers: false)
    |> Stream.transform(nil, fn
      headers, nil ->
        {[], headers}

      row, headers ->
        {[
           Enum.zip(headers, row)
           |> Map.new(fn {k, v} ->
             {k |> String.replace(" ", "") |> Macro.underscore() |> String.to_atom(),
              String.trim(v)}
           end)
         ], headers}
    end)
    |> Enum.to_list()
  end

  defp style(assigns) do
    ~H"""
    <style>
      .details-body { height: <%= @detail_body_height %>mm; }
      .detail { padding-left: 5px; height: <%= @detail_height %>mm; vertical-align: middle; align-items : center; }
      .page { width: 210mm; min-height: 290mm; padding: 5mm; }

      @media print {
        @page { size: A4; margin: 0mm; }
        body { width: 210mm; height: 290mm; margin: 0mm; }
        html { margin: 0mm; }
        .page { padding: 5mm; page-break-after: always;} }

      .form-title { text-align: center; }
      .date { text-align: right; width: 100%; }
      .amount { margin-top: 5px; margin-bottom: 5px; }
      .voucher { border-bottom: 1px black solid; padding-bottom: 20px; margin-bottom: 25px; }
    </style>
    """
  end
end
