defmodule FullCircleWeb.ReportLive.Print do
  use FullCircleWeb, :live_view

  @impl true
  def mount(params, _session, socket) do
    detail_body_height = 245
    detail_height = 5.5
    chunk = (detail_body_height / detail_height) |> floor

    {ac, data} =
      fill_data(socket, params["report"], params["name"], params["fdate"], params["tdate"])

    {:ok,
     socket
     |> assign(:detail_body_height, detail_body_height)
     |> assign(:detail_height, detail_height)
     |> assign(:chunk_number, Enum.chunk_every(data, chunk) |> Enum.count())
     |> assign(:detail_chunks, Enum.chunk_every(data, chunk))
     |> assign(:data, data)
     |> assign(:account, ac)
     |> assign(page_title: gettext("Print"))
     |> assign(:fdate, Date.from_iso8601!(params["fdate"]))
     |> assign(:tdate, Date.from_iso8601!(params["tdate"]))}
  end

  defp fill_data(socket, "contacttrans", name, fdate, tdate) do
    ac =
      FullCircle.Accounting.get_contact_by_name(
        name,
        socket.assigns.current_company,
        socket.assigns.current_user
      )

    data =
      FullCircle.Reporting.contact_transactions(
        ac,
        Date.from_iso8601!(fdate),
        Date.from_iso8601!(tdate),
        socket.assigns.current_company
      )

    {data, _} =
      Enum.map_reduce(data, Decimal.new("0"), fn txn, acc ->
        {
          Map.merge(txn, %{balance: Decimal.add(acc, txn.amount)}),
          Decimal.add(acc, txn.amount)
        }
      end)

    {ac, data}
  end

  defp fill_data(socket, "actrans", name, fdate, tdate) do
    ac =
      FullCircle.Accounting.get_account_by_name(
        name,
        socket.assigns.current_company,
        socket.assigns.current_user
      )

    data =
      FullCircle.Reporting.account_transactions(
        ac,
        Date.from_iso8601!(fdate),
        Date.from_iso8601!(tdate),
        socket.assigns.current_company
      )

    {data, _} =
      Enum.map_reduce(data, Decimal.new("0"), fn txn, acc ->
        {
          Map.merge(txn, %{balance: Decimal.add(acc, txn.amount)}),
          Decimal.add(acc, txn.amount)
        }
      end)

    {ac, data}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="print-me" class="print-here">
      <%= style(assigns) %>
      <%= Enum.map 1..@chunk_number, fn n -> %>
        <div class="page">
          <span class="header">Transactions: </span>
          <span class="header has-text-weight-bold"><%= @account.name %></span>
          <div class="between">
            <span>
              From: <span class="has-text-weight-bold"><%= @fdate %></span>
            </span>
            <span>To: <span class="has-text-weight-bold"><%= @tdate %></span></span>
          </div>
          <div class="details-body is-size-6">
            <div class="details-header has-text-weight-bold">
              <span class="doc_date"> Date </span>
              <span class="doc_type"> Doc Type </span>
              <span class="doc_no"> Doc No </span>
              <span class="particulars"> Particulars </span>
              <span class="debit"> Debit </span>
              <span class="credit"> Credit </span>
            </div>
            <%= previous_page_balance(n, assigns) %>
            <%= for txn <- Enum.at(@detail_chunks, n - 1) do %>
              <%= txn_detail(txn, assigns) %>
            <% end %>
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
    <div class="footer has-text-weight-bold">
      <span class="doc_date"></span>
      <span class="doc_type"></span>
      <span class="doc_no"></span>
      <span class="particulars"> Balance </span>
      <span class="debit">
        <%= if(Decimal.gt?((Enum.at(@detail_chunks, @n - 1) |> List.last()).balance, 0),
          do: (Enum.at(@detail_chunks, @n - 1) |> List.last()).balance,
          else: nil
        )
        |> Number.Delimit.number_to_delimited() %>
      </span>

      <span class="credit">
        <%= if(Decimal.gt?((Enum.at(@detail_chunks, @n - 1) |> List.last()).balance, 0),
          do: nil,
          else: Decimal.abs((Enum.at(@detail_chunks, @n - 1) |> List.last()).balance)
        )
        |> Number.Delimit.number_to_delimited() %>
      </span>
    </div>
    <div class="page-count"><%= "page #{@n} of #{@chunk_number}" %></div>
    """
  end

  defp previous_page_balance(n, assigns) do
    assigns = assign(assigns, :n, n)

    ~H"""
    <%= if !Decimal.eq?((Enum.at(@detail_chunks, @n - 1) |> List.first).balance, (Enum.at(@detail_chunks, @n - 1) |> List.first).amount) do %>
      <div class="detail">
        <span class="doc_date">-</span>
        <span class="doc_type">-</span>
        <span class="doc_no">-</span>
        <span class="particulars">Balance Previous Page</span>

        <span class="debit">
          <%= if(Decimal.gt?((Enum.at(@detail_chunks, @n - 2) |> List.last()).balance, 0),
            do: (Enum.at(@detail_chunks, @n - 2) |> List.last()).balance,
            else: nil
          )
          |> Number.Delimit.number_to_delimited() %>
        </span>

        <span class="credit">
          <%= if(Decimal.gt?((Enum.at(@detail_chunks, @n - 2) |> List.last()).balance, 0),
            do: nil,
            else: Decimal.abs((Enum.at(@detail_chunks, @n - 2) |> List.last()).balance)
          )
          |> Number.Delimit.number_to_delimited() %>
        </span>
      </div>
    <% end %>
    """
  end

  defp txn_detail(txn, assigns) do
    assigns = assign(assigns, :txn, txn)

    ~H"""
    <div class="detail">
      <span class="doc_date">
        <%= @txn.doc_date |> FullCircleWeb.Helpers.format_date() %>
      </span>
      <span class="doc_type">
        <%= @txn.doc_type %>
      </span>
      <span class="doc_no">
        <%= @txn.doc_no %>
      </span>
      <span class="particulars">
        <%= @txn.particulars %>
      </span>
      <span class="debit">
        <%= if(Decimal.gt?(@txn.amount, 0), do: @txn.amount, else: nil)
        |> Number.Delimit.number_to_delimited() %>
      </span>
      <span class="credit">
        <%= if(Decimal.gt?(@txn.amount, 0), do: nil, else: Decimal.abs(@txn.amount))
        |> Number.Delimit.number_to_delimited() %>
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
      .between { float: right;}

      .details-header { display: flex; text-align: center; padding-bottom: 2mm; padding-top: 2mm; border-bottom: 1px solid black; border-top: 1px solid black;}
      .doc_date { width: 25mm; text-align: center; }
      .doc_type { width: 30mm; text-align: center; }
      .doc_no { width: 28mm; text-align: center; }
      .particulars { max-height: <%= @detail_height %>mm; width: 60mm; text-align: center; overflow: hidden; }
      .debit { width: 28mm; text-align: right; }
      .credit { width: 28mm; text-align: right; }

      .footer { margin-top: 13mm; display: flex; min-height: 8mm; border-bottom: 1px solid black; border-top: 1px solid black; padding-top: 1.5mm;}
      .page-count { float: right; }
    </style>
    """
  end
end
