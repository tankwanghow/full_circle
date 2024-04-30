defmodule FullCircleWeb.ReportLive.Statement.Print do
  use FullCircleWeb, :live_view

  alias FullCircleWeb.Helpers

  @impl true
  def mount(params, _session, socket) do
    detail_body_height = 180
    detail_height = 6
    chunk = (detail_body_height / detail_height) |> floor

    contacts = fill_data(socket, params["ids"], params["fdate"], params["tdate"])

    contacts =
      contacts
      |> Enum.map(fn cont ->
        cont
        |> Map.merge(%{
          chunk_number: Enum.chunk_every(cont.transactions, chunk) |> Enum.count()
        })
        |> Map.merge(%{
          detail_chunks: Enum.chunk_every(cont.transactions, chunk)
        })
      end)

    {:ok,
     socket
     |> assign(:detail_body_height, detail_body_height)
     |> assign(:detail_height, detail_height)
     |> assign(:contacts, contacts)
     |> assign(page_title: gettext("Print"))
     |> assign(:fdate, Date.from_iso8601!(params["fdate"]))
     |> assign(:tdate, Date.from_iso8601!(params["tdate"]))}
  end

  defp fill_data(socket, ids, fdate, tdate) do
    ids = String.split(ids, ",")

    FullCircle.Reporting.statements(
      ids,
      Date.from_iso8601!(fdate),
      Date.from_iso8601!(tdate),
      socket.assigns.current_company
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="print-me" class="print-here">
      <%= style(assigns) %>
      <%= for contact <- @contacts do %>
        <%= Enum.map 1..contact.chunk_number, fn n -> %>
          <div class="page">
            <%= letter_head_data(assigns) %>
            <%= statement_header(assigns, n, contact.chunk_number, contact) %>
            <%= print_transaction_header(assigns) %>
            <div class="details">
              <%= for txn <- Enum.at(contact.detail_chunks, n - 1) do %>
                <%= print_transaction(assigns, txn) %>
              <% end %>
            </div>
            <%= if(n == contact.chunk_number,
              do: print_aging(assigns, contact.aging, contact.pd_chqs),
              else: "continue...."
            ) %>
          </div>
        <% end %>
      <% end %>
    </div>
    """
  end

  defp print_transaction_header(assigns) do
    ~H"""
    <div class="txn header">
      <div class="doc_date">Date</div>
      <div class="doc_info">Transaction</div>
      <div class="parti">Particulars</div>
      <div class="amount">Amount</div>
      <div class="running_sum">Balance</div>
    </div>
    """
  end

  defp print_transaction(assigns, txn) do
    assigns = assign(assigns, :txn, txn)

    ~H"""
    <div class="txn">
      <div class="doc_date"><%= @txn.doc_date %></div>
      <div class="doc_info"><%= @txn.doc_type %> <%= @txn.doc_no %></div>
      <div class="parti"><%= @txn.particulars |> String.slice(0..40) %></div>
      <div class="amount"><%= @txn.amount |> Number.Delimit.number_to_delimited() %></div>
      <div class="running_sum"><%= @txn.running |> Number.Delimit.number_to_delimited() %></div>
    </div>
    """
  end

  defp print_aging(assigns, aging, pd_chqs) do
    assigns = assign(assigns, :aging, aging) |> assign(:pd_chqs, pd_chqs)

    ~H"""
    <div class="aging_group">
      <div class="aging">
        <div class="aging_p header">Current</div>
        <div class="aging_p header">30-60 days</div>
        <div class="aging_p header">60-90 days</div>
        <div class="aging_p header">90-120 days</div>
        <div class="aging_p header">120++ days</div>
        <div class="aging_p header total">Total</div>
        <div :if={@pd_chqs} class="aging_p header"><%= @pd_chqs.cheques %> PD Chqs</div>
      </div>
    </div>
    <div class="aging_group">
      <div :if={@aging} class="aging">
        <div class="aging_p"><%= @aging.p1 |> Number.Delimit.number_to_delimited() %></div>
        <div class="aging_p"><%= @aging.p2 |> Number.Delimit.number_to_delimited() %></div>
        <div class="aging_p"><%= @aging.p3 |> Number.Delimit.number_to_delimited() %></div>
        <div class="aging_p"><%= @aging.p4 |> Number.Delimit.number_to_delimited() %></div>
        <div class="aging_p"><%= @aging.p5 |> Number.Delimit.number_to_delimited() %></div>
        <div class="aging_p total">
          <%= (@aging.p1 + @aging.p2 + @aging.p3 + @aging.p4 + @aging.p5)
          |> Number.Delimit.number_to_delimited() %>
        </div>
        <div :if={@pd_chqs} class="aging_p">
          <%= @pd_chqs.amount |> Number.Delimit.number_to_delimited() %>
        </div>
      </div>
      <div :if={is_nil(@aging)} class="aging">
        <div class="aging_p">0.00</div>
        <div class="aging_p">0.00</div>
        <div class="aging_p">0.00</div>
        <div class="aging_p">0.00</div>
        <div class="aging_p">0.00</div>
        <div class="aging_p total">0.00</div>
        <div :if={@pd_chqs} class="aging_p">0.00</div>
      </div>
    </div>
    """
  end

  def statement_header(assigns, page, pages, contact) do
    assigns =
      assigns |> assign(:contact, contact) |> assign(:page, page) |> assign(:pages, pages)

    ~H"""
    <div class="statement-header">
      <div class="is-size-6">TO</div>
      <div class="customer">
        <div class="is-size-5 has-text-weight-bold"><%= @contact.name %></div>
        <div class="statement-info">
          <div>
            From Date: <span class="has-text-weight-bold"><%= Helpers.format_date(@fdate) %></span>
          </div>
          <div>
            To Date: <span class="has-text-weight-bold"><%= Helpers.format_date(@tdate) %></span>
          </div>
          <div class="page-info"><%= "page #{@page} of #{@pages}" %></div>
        </div>
        <div><%= @contact.address1 %></div>
        <div><%= @contact.address2 %></div>
        <div>
          <%= Enum.join(
            [
              @contact.city,
              @contact.zipcode,
              @contact.state,
              @contact.country
            ],
            " "
          ) %>
        </div>
        <%= @contact.reg_no %>
      </div>
    </div>
    """
  end

  def letter_head_data(assigns) do
    ~H"""
    <div class="is-size-3 has-text-weight-bold"><%= @current_company.name %></div>
    <div><%= @current_company.address1 %>, <%= @current_company.address2 %></div>
    <div class="doctype">STATEMENT</div>
    <div>
      <%= Enum.join(
        [
          @current_company.zipcode,
          @current_company.city,
          @current_company.state,
          @current_company.country
        ],
        ", "
      ) %>
    </div>
    <div>
      Tel: <%= @current_company.tel %> RegNo: <%= @current_company.reg_no %> Email: <%= @current_company.email %>
    </div>
    """
  end

  defp style(assigns) do
    ~H"""
    <style>
      .details { height: <%= @detail_body_height %>mm; }
      .page { width: 210mm; min-height: 290mm; padding: 5mm; }

      @media print {
        @page { size: A4; margin: 0mm; }
        body { width: 210mm; height: 290mm; margin: 0mm; }
        html { margin: 0mm; }
        .page { padding-left: 5mm; padding-right: 5mm; page-break-after: always;} }

      .doctype { float: right; font-weight: bold; font-size: 1.5rem; }

      .statement-header { height: 40mm; margin-top: 3mm; border-top: 1px solid black; }
      .statement-header .customer { padding-left: 3mm; padding-top: 2mm; }
      .statement-header .statement-info { float: right; text-align: right; }
      .statement-header .page-info { margin-top: 8mm; }

      .txn.header { font-weight: bold; border-top: 2px solid black; border-bottom: 2px solid black; height: 8mm; padding-top: 1mm; margin-bottom: 2mm; }

      .txn { display: flex; height: <%= @detail_height %>mm;  }
      .txn .doc_date { width: 12%; text-align: left; }
      .txn .doc_info { width: 21%; text-align: center; }
      .txn .parti { width: 40%; text-align: center; overflow: clip;}
      .txn .amount { width: 12%; text-align: right; }
      .txn .running_sum { width: 15%; text-align: right; }

      .aging_group { bottom: 10px;}
      .aging { display: flex; gap: 2px; margin-bottom: 1px;}
      .aging .aging_p { width: 16.67%; text-align: center; border: 1px solid black; border-radius: 5px; padding: 4px;}
      .aging .aging_p.total { font-weight: bold; }
    </style>
    """
  end
end
