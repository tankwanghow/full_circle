defmodule FullCircleWeb.InvoiceLive.Print do
  use FullCircleWeb, :live_view

  import FullCircleWeb.Helpers
  alias FullCircle.Billing

  @impl true
  def mount(%{"id" => id, "pre_print" => pre_print}, _session, socket) do
    {:ok, fill_assigns(id, socket) |> assign(:pre_print, pre_print)}
  end

  defp fill_assigns(id, socket) do
    invoice =
      Billing.get_print_invoice!(
        id,
        socket.assigns.current_company,
        socket.assigns.current_user
      )

    contact =
      FullCircle.StdInterface.get!(
        FullCircle.Accounting.Contact,
        invoice.contact_id
      )

    company = FullCircle.Sys.get_company!(socket.assigns.current_company.id)

    detail_body_height = 135
    detail_height = 13
    chunk = (detail_body_height / detail_height) |> floor

    socket
    |> assign(:detail_body_height, detail_body_height)
    |> assign(:detail_height, detail_height)
    |> assign(:back, "/companies/#{socket.assigns.current_company.id}/invoices")
    |> assign(:invoice, invoice)
    |> assign(:company, company)
    |> assign(:contact, contact)
    |> assign(:chunk_number, Enum.chunk_every(invoice.invoice_details, chunk) |> Enum.count())
    |> assign(:detail_chunks, Enum.chunk_every(invoice.invoice_details, chunk))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="print-me" class="print-here">
      <%= pre_print_style(assigns) %>
      <%= if(@pre_print == "false", do: full_style(assigns)) %>
      <%= Enum.map 1..@chunk_number, fn n -> %>
        <div id="page" class="">
          <div class="letter-head">
            <%= if(@pre_print == "true", do: "", else: letter_head_data(assigns)) %>
          </div>
          <div class="doctype is-size-4 has-text-weight-semibold">INVOICE</div>
          <%= invoice_header(assigns) %>
          <%= detail_header(assigns) %>
          <div class="details-body is-size-6">
            <%= for invd <- Enum.at(@detail_chunks, n - 1) do %>
              <%= invoice_detail(invd, assigns) %>
            <% end %>
          </div>
          <%= if(n == @chunk_number,
            do: invoice_footer(n, @chunk_number, assigns),
            else: invoice_footer("continue", n, @chunk_number, assigns)
          ) %>
          <%= if(@pre_print == "true", do: "", else: letter_foot(assigns)) %>
        </div>
      <% end %>
    </div>
    """
  end

  defp invoice_detail(invd, assigns) do
    assigns = assign(assigns, :invd, invd)

    ~H"""
    <div class="detail">
      <span class="particular">
        <div>
          <%= @invd.good_name %>
          <%= if(Decimal.gt?(@invd.package_qty, 0), do: " - #{@invd.package_qty}", else: "") %>
          <%= if(!is_nil(@invd.package_name) and @invd.package_name != "-",
            do: "(#{@invd.package_name})",
            else: ""
          ) %>
        </div>
        <div class="is-size-7">
          <%= if(@invd.descriptions != "" and !is_nil(@invd.descriptions),
            do: "#{@invd.descriptions}",
            else: ""
          ) %>
        </div>
      </span>
      <span class="qty">
        <%= @invd.quantity %> <%= if @invd.unit == "-", do: "", else: @invd.unit %>
      </span>
      <span class="price"><%= format_unit_price(@invd.unit_price) %></span>
      <span class="disc">
        <%= if(Decimal.eq?(@invd.discount, 0),
          do: "-",
          else: Number.Delimit.number_to_delimited(@invd.discount)
        ) %>
      </span>
      <span class="total">
        <div><%= Number.Delimit.number_to_delimited(@invd.good_amount) %></div>
        <span class="is-size-7 is-italic">
          <%= if(!Decimal.eq?(@invd.tax_rate, 0), do: @invd.tax_code, else: "") %>
          <%= if(Decimal.eq?(@invd.tax_rate, 0), do: "", else: "#{@invd.tax_rate}%") %>
        </span>
        <%= if(Decimal.eq?(@invd.tax_amount, 0),
          do: "",
          else: Number.Delimit.number_to_delimited(@invd.tax_amount)
        ) %>
      </span>
    </div>
    """
  end

  defp invoice_footer("continue", page, pages, assigns) do
    assigns = assign(assigns, :page, page) |> assign(:pages, pages)

    ~H"""
    <div class="is-size-5 descriptions">
      <div class="is-size-7 page-count"><%= "page #{@page} of #{@pages}" %></div>
    </div>
    <div class="invoice-footer" />
    """
  end

  defp invoice_footer(page, pages, assigns) do
    assigns = assign(assigns, :page, page) |> assign(:pages, pages)

    ~H"""
    <div class="is-size-5 descriptions">
      <%= insert_new_html_newline(@invoice.descriptions) %>
      <div class="is-size-7 page-count"><%= "page #{@page} of #{@pages}" %></div>
    </div>
    <div class="invoice-footer">
      <span>
        Goods Amount: <%= Number.Delimit.number_to_delimited(@invoice.invoice_good_amount) %>
      </span>
      <span>
        Tax Amount: <%= Number.Delimit.number_to_delimited(@invoice.invoice_tax_amount) %>
      </span>
      <span class="has-text-weight-bold">
        Invoice Amount: <%= Number.Delimit.number_to_delimited(@invoice.invoice_amount) %>
      </span>
    </div>
    """
  end

  defp letter_foot(assigns) do
    ~H"""
    <div class="letter-hoot">
      <div class="terms is-size-7">
        <div>The above goods are delivered in good order and condition.</div>
        <div>Please make payment before the "Pay Due Date"</div>
        <div>All cheques should be made payable to the company & crossed "A/C Payee only"</div>
      </div>
      <div class="sign">Authorise Signature</div>
      <div class="sign">Reciver Signature</div>
    </div>
    """
  end

  defp detail_header(assigns) do
    ~H"""
    <div class="details-header has-text-weight-bold">
      <div class="particular">Particulars</div>
      <div class="qty">Quantity</div>
      <div class="price">Price</div>
      <div class="disc">Discount</div>
      <div class="total">Total & Tax</div>
    </div>
    """
  end

  defp invoice_header(assigns) do
    ~H"""
    <div class="invoice-header">
      <div class="is-size-6">TO</div>
      <div class="customer">
        <div class="is-size-5 has-text-weight-bold"><%= @invoice.contact_name %></div>
        <div><%= @contact.address1 %></div>
        <div><%= @contact.address2 %></div>
        <div>
          <%= Enum.join([@contact.city, @contact.zipcode, @contact.state, @contact.country], " ") %>
        </div>
        <%= @contact.reg_no %>
      </div>
      <div class="invoice-info">
        <div>
          Invoice Date:
          <span class="has-text-weight-bold"><%= format_date(@invoice.invoice_date) %></span>
        </div>
        <div>
          Pay By: <span class="has-text-weight-bold"><%= format_date(@invoice.due_date) %></span>
        </div>
        <div>Invoice No: <span class="has-text-weight-bold"><%= @invoice.invoice_no %></span></div>
      </div>
    </div>
    """
  end

  defp letter_head_data(assigns) do
    ~H"""
    <div class="is-size-3 has-text-weight-bold"><%= @company.name %></div>
    <div><%= @company.address1 %>, <%= @company.address2 %></div>
    <div>
      <%= Enum.join([@company.zipcode, @company.city, @company.state, @company.country], ", ") %>
    </div>
    <div>
      Tel: <%= @company.tel %> RegNo: <%= @company.reg_no %> Email: <%= @company.email %>
    </div>
    """
  end

  defp full_style(assigns) do
    ~H"""
    <style>
      .letter-head { border-bottom: 0.5mm solid black; }
      .invoice-header { border-bottom: 0.5mm solid black; }
      .invoice-footer { border-bottom: 0.5mm solid black; }
      .terms { height: 15mm; }
      .sign { padding: 3mm; border-top: 2px dotted black; width: 30%; text-align: center; float: right; margin-left: 2mm; margin-top: 15mm;}
    </style>
    """
  end

  defp pre_print_style(assigns) do
    ~H"""
    <style>
      .details-body { height: <%= @detail_body_height %>mm; }
      .detail { display: flex; height: <%= @detail_height %>mm; vertical-align: middle; align-items : center; }
      #page { width: 210mm; min-height: 297mm; }
      @media print {
        @page { size: A4; margin: 0;}
        html, body { width: 210mm; height: 297mm; }
        #page { padding: 5mm; page-break-after: avoid; }
      }
      .letter-head { padding-bottom: 2mm; margin-bottom: 2mm; height: 28mm;}
      .doctype { float: right; margin-top: -20mm; margin-right: 0mm; }
      .invoice-info { float: right; }
      .invoice-header { width: 100%; height: 40mm; border-bottom: 0.5mm solid black; }
      .customer { padding-left: 2mm; float: left;}
      .invoice-info div { margin-bottom: 2mm; text-align: right; }
      .details-header { display: flex; text-align: center; padding-bottom: 2mm; padding-top: 2mm; border-bottom: 0.5mm solid black; }
      .particular { width: 80mm; text-align: left; }
      .qty { width: 32mm; text-align: center; }
      .price { width: 27mm; text-align: center; }
      .disc { width: 27mm; text-align: center; }
      .total { width: 40mm; text-align: right; }
      .invoice-footer { margin-bottom: 1mm; padding: 3mm 0 3mm 0; text-align: right; border-top: 0.5mm solid black;}
      .invoice-footer span { padding-left: 5mm; }
      .invoice-footer span span { padding-left: 0; }
      .descriptions { font-style: italic; height: 13mm;}
      .page-count { float: right; }
    </style>
    """
  end
end
