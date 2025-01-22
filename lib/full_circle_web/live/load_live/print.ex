defmodule FullCircleWeb.LoadLive.Print do
  use FullCircleWeb, :live_view

  import FullCircleWeb.Helpers
  alias FullCircle.Product

  @impl true
  def mount(%{"id" => id, "pre_print" => pre_print}, _session, socket) do
    ids = [id]

    {:ok,
     socket
     |> assign(page_title: gettext("Print"))
     |> assign(:pre_print, pre_print)
     |> set_page_defaults()
     |> fill_orders(ids)}
  end

  @impl true
  def mount(%{"ids" => ids, "pre_print" => pre_print}, _, socket) do
    ids = String.split(ids, ",")

    {:ok,
     socket
     |> assign(page_title: gettext("Print"))
     |> assign(:pre_print, pre_print)
     |> set_page_defaults()
     |> fill_orders(ids)}
  end

  defp set_page_defaults(socket) do
    socket
    |> assign(:detail_body_height, 145)
    |> assign(:detail_height, 10)
    |> assign(:company, FullCircle.Sys.get_company!(socket.assigns.current_company.id))
  end

  defp fill_orders(socket, ids) do
    chunk = (socket.assigns.detail_body_height / socket.assigns.detail_height) |> floor

    orders =
      Product.get_print_orders!(
        ids,
        socket.assigns.current_company,
        socket.assigns.current_user
      )
      |> Enum.map(fn order ->
        order
        |> Map.merge(%{
          chunk_number: Enum.chunk_every(order.order_details, chunk) |> Enum.count()
        })
        |> Map.merge(%{
          detail_chunks: Enum.chunk_every(order.order_details, chunk)
        })
      end)

    socket
    |> assign(:orders, orders)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="print-me" class="print-here">
      {pre_print_style(assigns)}
      {if(@pre_print == "false", do: full_style(assigns))}
      <%= for order <- @orders do %>
        <%= Enum.map 1..order.chunk_number, fn n -> %>
          <div class="page">
            <div class="letter-head">
              {if(@pre_print == "true", do: "", else: letter_head_data(assigns))}
            </div>
            <div class="doctype is-size-4 has-text-weight-semibold">ORDER</div>
            {order_header(order, assigns)}
            {detail_header(assigns)}
            <div class="details-body is-size-6">
              <%= for ldd <- Enum.at(order.detail_chunks, n - 1) do %>
                {order_detail(ldd, assigns)}
              <% end %>
            </div>
            {if(n == order.chunk_number,
              do: order_footer("", n, order.chunk_number, assigns),
              else: order_footer("continue", n, order.chunk_number, assigns)
            )}
            {if(@pre_print == "true", do: "", else: letter_foot(order, assigns))}
          </div>
        <% end %>
      <% end %>
    </div>
    """
  end

  def detail_header(assigns) do
    ~H"""
    <div class="details-header has-text-weight-bold">
      <div class="goods">Goods</div>
      <div class="pack">Packaging</div>
      <div class="order_pack">Order Pack</div>
      <div class="order_qty">Order Qty</div>
      <div class="order_pack">Price</div>
    </div>
    """
  end

  def order_detail(ldd, assigns) do
    assigns = assign(assigns, :ldd, ldd)

    ~H"""
    <div class="details-data">
      <div class="goods">{@ldd.good_name} - {@ldd.descriptions}</div>
      <div class="pack">{@ldd.package_name}</div>
      <div class="order_pack">{@ldd.order_pack_qty |> int_or_float_format}</div>
      <div class="order_qty">{@ldd.order_qty |> int_or_float_format} {@ldd.unit}</div>
      <div class="order_pack">{@ldd.unit_price |> Number.Delimit.number_to_delimited()}</div>
    </div>
    """
  end

  def order_footer("", page, pages, assigns) do
    assigns = assign(assigns, :page, page) |> assign(:pages, pages)

    ~H"""
    <div class="order-footer"></div>
    <span class="page-count">{"page #{@page} of #{@pages}"}</span>
    """
  end

  def order_footer("continue", page, pages, assigns) do
    assigns = assign(assigns, :page, page) |> assign(:pages, pages)

    ~H"""
    <div class="descriptions">....continue....</div>
    <div class="order-footer"></div>
    <span class="page-count">{"page #{@page} of #{@pages}"}</span>
    """
  end

  def letter_foot(inv, assigns) do
    assigns = assigns |> assign(:inv, inv)

    ~H"""
    <div class="letter-foot">
      <div class="terms">{@inv.descriptions}</div>
      <div class="sign">Seller Sign</div>
      <div class="sign">Manager Sign</div>
      <div class="sign">Buyer Sign</div>
    </div>
    """
  end

  def order_header(order, assigns) do
    assigns = assigns |> assign(:order, order)

    ~H"""
    <div class="order-header">
      <div class="is-size-6">TO</div>
      <div class="customer">
        <div class="is-size-5 has-text-weight-bold">{@order.contact.name}</div>
        <div>{@order.contact.address1}</div>
        <div>{@order.contact.address2}</div>
        <div>
          {Enum.join(
            [
              @order.contact.city,
              @order.contact.zipcode,
              @order.contact.state,
              @order.contact.country
            ],
            " "
          )}
        </div>
        {@order.contact.reg_no}
      </div>
      <div class="order-info">
        <div>Order No: <span class="has-text-weight-bold">{@order.order_no}</span></div>
        <div>
          OrderDate: <span class="has-text-weight-bold">{format_date(@order.order_date)}</span>
        </div>
        <div>
          ETA Date: <span class="has-text-weight-bold">{@order.etd_date |> format_date}</span>
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
      .order-header { border-bottom: 0.5mm solid black; }
      .order-footer {  }
      .terms { height: 15mm; }
      .sign { padding: 3mm; border-top: 2px dotted black; width: 30%; text-align: center; float: right; margin-left: 6.65mm; margin-top: 15mm;}
    </style>
    """
  end

  def pre_print_style(assigns) do
    ~H"""
    <style>
      .details-body { height: <%= @detail_body_height %>mm; }
      .details-data { display: flex; height: <%= @detail_height %>mm; vertical-align: middle; align-items: center; }
      .page { width: 210mm; min-height: 290mm; padding: 5mm; }

      @media print {
        @page { size: A4; margin: 0mm; }
        body { width: 210mm; height: 290mm; margin: 0mm; }
        html { margin: 0mm; }
        .page { padding: 5mm; page-break-after: always;} }

      .letter-head { padding-bottom: 2mm; margin-bottom: 2mm; height: 28mm;}
      .doctype { float: right; margin-top: -20mm; margin-right: 0mm; }
      .order-info { float: right; }
      .order-header { width: 100%; height: 40mm; border-bottom: 0.5mm solid black; }
      .customer { padding-left: 2mm; float: left;}
      .order-info div { margin-bottom: 2mm; text-align: right; }

      .details-header { display: flex; padding-bottom: 2mm; padding-top: 2mm; border-bottom: 0.5mm solid black; }

      .goods { width: 80mm; text-align: left;  }
      .pack { width: 40mm; text-align: left; }
      .order_pack { width: 30mm; text-align: center; }
      .order_qty { width: 30mm; text-align: center; }

      .order-footer { min-height: 10mm; }
      .descriptions { min-height: 6mm; }

      .order-amount { display: flex; border-top: 0.5mm solid black;  }

      .order-amount div  { width: 33%; text-align: right; padding-top: 2mm;}
      .order-amount .taxamt { width: 33%; text-align: right; }
      .order-amount .invamt { width: 33%; text-align: right; }
      .page-count { float: right; padding-top: 1mm;}
    </style>
    """
  end
end
