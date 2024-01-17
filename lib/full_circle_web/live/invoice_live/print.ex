defmodule FullCircleWeb.InvoiceLive.Print do
  use FullCircleWeb, :live_view

  import FullCircleWeb.Helpers
  alias FullCircle.Billing

  @impl true
  def mount(%{"id" => id, "pre_print" => pre_print}, _session, socket) do
    ids = [id]

    {:ok,
     socket
     |> assign(page_title: gettext("Print"))
     |> assign(:pre_print, pre_print)
     |> set_page_defaults()
     |> fill_invoices(ids)}
  end

  @impl true
  def mount(%{"ids" => ids, "pre_print" => pre_print}, _, socket) do
    ids = String.split(ids, ",")

    {:ok,
     socket
     |> assign(page_title: gettext("Print"))
     |> assign(:pre_print, pre_print)
     |> set_page_defaults()
     |> fill_invoices(ids)}
  end

  defp set_page_defaults(socket) do
    socket
    |> assign(:detail_body_height, 150)
    |> assign(:detail_height, 10)
    |> assign(:company, FullCircle.Sys.get_company!(socket.assigns.current_company.id))
  end

  defp fill_invoices(socket, ids) do
    chunk = (socket.assigns.detail_body_height / socket.assigns.detail_height) |> floor

    invoices =
      Billing.get_print_invoices!(
        ids,
        socket.assigns.current_company,
        socket.assigns.current_user
      )
      |> Enum.map(fn invoice ->
        invoice
        |> Map.merge(%{
          chunk_number: Enum.chunk_every(invoice.invoice_details, chunk) |> Enum.count()
        })
        |> Map.merge(%{
          detail_chunks: Enum.chunk_every(invoice.invoice_details, chunk)
        })
      end)

    socket
    |> assign(:invoices, invoices)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="print-me" class="print-here">
      <%= pre_print_style(assigns) %>
      <%= if(@pre_print == "false", do: full_style(assigns)) %>
      <%= for invoice <- @invoices do %>
        <%= Enum.map 1..invoice.chunk_number, fn n -> %>
          <div class="page">
            <div class="letter-head">
              <%= if(@pre_print == "true", do: "", else: letter_head_data(assigns)) %>
            </div>
            <div class="doctype is-size-4 has-text-weight-semibold">INVOICE</div>
            <%= invoice_header(invoice, n, invoice.chunk_number, assigns) %>
            <%= detail_header(assigns) %>
            <div class="details-body is-size-6">
              <%= for invd <- Enum.at(invoice.detail_chunks, n - 1) do %>
                <%= invoice_detail(invd, assigns) %>
              <% end %>
            </div>
            <%= if(n == invoice.chunk_number,
              do: invoice_footer(invoice, assigns),
              else: invoice_footer("continue", assigns)
            ) %>
            <%= if(@pre_print == "true", do: "", else: letter_foot(invoice, assigns)) %>
          </div>
        <% end %>
      <% end %>
    </div>
    """
  end

  def invoice_detail(invd, assigns) do
    assigns = assign(assigns, :invd, invd)

    ~H"""
    <div class="detail">
      <div class="particular">
        <div>
          <%= @invd.good_name %>
          <%= if(Decimal.gt?(@invd.package_qty, 0), do: " - #{@invd.package_qty}", else: "") %>
          <%= if(!is_nil(@invd.package_name) and @invd.package_name != "-",
            do: "(#{@invd.package_name})",
            else: ""
          ) %>
        </div>
        <div>
          <%= if(@invd.descriptions != "" and !is_nil(@invd.descriptions),
            do: "#{@invd.descriptions}",
            else: ""
          ) %>
        </div>
      </div>
      <div class="qty">
        <%= if Decimal.integer?(@invd.quantity),
          do: Decimal.to_integer(@invd.quantity),
          else: @invd.quantity %> <%= if @invd.unit == "-", do: "", else: @invd.unit %>
      </div>
      <div class="price"><%= format_unit_price(@invd.unit_price) %></div>
      <div class="disc">
        <%= if(Decimal.eq?(@invd.discount, 0),
          do: "-",
          else: Number.Delimit.number_to_delimited(@invd.discount)
        ) %>
      </div>
      <div class="total">
        <div><%= Number.Delimit.number_to_delimited(@invd.good_amount) %></div>

        <%= if Decimal.gt?(@invd.tax_amount, 0) do %>
          <div class="is-size-7 is-italic">
            <%= @invd.tax_code %>
            <%= Number.Percentage.number_to_percentage(@invd.tax_rate) %>
            <%= Number.Delimit.number_to_delimited(@invd.tax_amount) %>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  def invoice_footer("continue", assigns) do
    ~H"""
    <div class="descriptions">....continue....</div>
    <div class="invoice-footer"></div>
    """
  end

  def invoice_footer(invoice, assigns) do
    assigns = assign(assigns, :invoice, invoice)

    ~H"""
    <div class="descriptions">
      <%= insert_new_html_newline(@invoice.descriptions) %>
    </div>
    <div class="invoice-footer">
      <div class="invoice-amount">
        <div class="goodamt">
          Goods Amount: <%= Number.Delimit.number_to_delimited(@invoice.invoice_good_amount) %>
        </div>
        <div class="taxamt">
          Tax Amount: <%= Number.Delimit.number_to_delimited(@invoice.invoice_tax_amount) %>
        </div>
        <div class="invamt has-text-weight-semibold">
          Invoice Amount: <%= Number.Delimit.number_to_delimited(@invoice.invoice_amount) %>
        </div>
      </div>
    </div>
    """
  end

  def letter_foot(inv, assigns) do
    assigns = assigns |> assign(:inv, inv)

    ~H"""
    <div class="letter-foot">
      <div class="terms is-size-7">
        <div>
          The above goods are delivered in good order and condition. Please make payment before the "Pay Due Date"
        </div>
        <div>All cheques should be made payable to the company & crossed "A/C Payee only"</div>
        <div class="is-size-6 has-text-weight-light is-italic">
          Issued By: <%= @inv.issued_by.user.email %>
        </div>
      </div>
      <div class="sign">Authorise Signature</div>
      <div class="sign">Reciver Signature</div>
    </div>
    """
  end

  def detail_header(assigns) do
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

  def invoice_header(invoice, page, pages, assigns) do
    assigns =
      assigns
      |> assign(:invoice, invoice)
      |> assign(:page, page)
      |> assign(:pages, pages)

    ~H"""
    <div class="invoice-header">
      <div class="is-size-6">TO</div>
      <div class="customer">
        <div class="is-size-5 has-text-weight-bold"><%= @invoice.contact.name %></div>
        <div><%= @invoice.contact.address1 %></div>
        <div><%= @invoice.contact.address2 %></div>
        <div>
          <%= Enum.join(
            [
              @invoice.contact.city,
              @invoice.contact.zipcode,
              @invoice.contact.state,
              @invoice.contact.country
            ],
            " "
          ) %>
        </div>
        <%= @invoice.contact.reg_no %>
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
        <span class="page-count"><%= "page #{@page} of #{@pages}" %></span>
      </div>
    </div>
    """
  end

  def letter_head_data(assigns) do
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

  def full_style(assigns) do
    ~H"""
    <style>
      .letter-head { border-bottom: 0.5mm solid black; }
      .letter-foot { top: 255mm; border-top: 0.5mm solid black; }
      .invoice-header { border-bottom: 0.5mm solid black; }
      .invoice-footer {  }
      .terms { height: 15mm; }
      .sign { padding: 3mm; border-top: 2px dotted black; width: 30%; text-align: center; float: right; margin-left: 2mm; margin-top: 5mm;}
    </style>
    """
  end

  def pre_print_style(assigns) do
    ~H"""
    <style>
      .details-body { height: <%= @detail_body_height %>mm; }
      .details-body div { vertical-align: top; }
      .detail { display: flex; height: <%= @detail_height %>mm; align-items : center;  line-height: 4mm; }
      .page { width: 210mm; min-height: 290mm; padding: 5mm; }

      @media print {
        @page { size: A4; margin: 0mm; }
        body { width: 210mm; height: 290mm; margin: 0mm; }
        html { margin: 0mm; }
        .page { padding-left: 10mm; padding-right: 10mm; page-break-after: always;} }

      .letter-head { padding-bottom: 2mm; margin-bottom: 5mm; height: 28mm;}
      .doctype { float: right; margin-top: -20mm; margin-right: 0mm; }
      .invoice-info { float: right; }
      .invoice-header { width: 100%; height: 40mm; border-bottom: 0.5mm solid black; }
      .customer { padding-left: 2mm; float: left;}
      .invoice-info div { margin-bottom: 2mm; text-align: right; }
      .details-header { display: flex; text-align: center; padding-bottom: 2mm; padding-top: 2mm; border-bottom: 0.5mm solid black; margin-bottom: 2mm;}
      .particular { width: 80mm; text-align: left;  height: 100%; }
      .qty { width: 32mm; text-align: center; height: 100%; }
      .price { width: 25mm; text-align: center;  height: 100%; }
      .disc { width: 24mm; text-align: center;  height: 100%; }
      .total { width: 45mm; text-align: right;  height: 100%; }

      .invoice-footer { min-height: 10mm; }
      .descriptions { min-height: 6mm; }

      .invoice-amount { display: flex; border-top: 0.5mm solid black;  }

      .invoice-amount div  { width: 33%; text-align: right; padding-top: 2mm;}
      .invoice-amount .taxamt { width: 33%; text-align: right; }
      .invoice-amount .invamt { width: 33%; text-align: right; }
      .page-count { float: right; padding-top: 1mm;}
    </style>
    """
  end
end
