defmodule FullCircleWeb.PaySlipLive.Print do
  use FullCircleWeb, :live_view

  import FullCircleWeb.Helpers
  alias FullCircle.PaySlipOp

  @impl true
  def mount(%{"id" => id, "pre_print" => pre_print}, _session, socket) do
    ids = [id]

    {:ok,
     socket
     |> assign(page_title: gettext("Print"))
     |> assign(:pre_print, pre_print)
     |> set_page_defaults()
     |> fill_pay_slips(ids)}
  end

  @impl true
  def mount(%{"ids" => ids, "pre_print" => pre_print}, _, socket) do
    ids = String.split(ids, ",")

    {:ok,
     socket
     |> assign(page_title: gettext("Print"))
     |> assign(:pre_print, pre_print)
     |> set_page_defaults()
     |> fill_pay_slips(ids)}
  end

  defp set_page_defaults(socket) do
    socket
    |> assign(:detail_body_height, 170)
    |> assign(:detail_height, 6)
    |> assign(:company, FullCircle.Sys.get_company!(socket.assigns.current_company.id))
  end

  defp fill_pay_slips(socket, ids) do
    chunk = (socket.assigns.detail_body_height / socket.assigns.detail_height) |> floor

    pay_slips =
      PaySlipOp.get_print_pay_slips(
        ids,
        socket.assigns.current_company
      )
      |> change_to_typeless_struct()
      |> Enum.map(fn ps ->
        ps
        |> Map.merge(%{
          chunk_number:
            Enum.chunk_every(
              ps.details,
              chunk
            )
            |> Enum.count()
        })
        |> Map.merge(%{
          detail_chunks:
            Enum.chunk_every(
              ps.details,
              chunk
            )
        })
      end)

    socket
    |> assign(:pay_slips, pay_slips)
  end

  defp change_to_typeless_struct(pss) do
    Enum.map(pss, fn x ->
      add =
        Enum.map(x.additions, fn x ->
          %{
            type: "income",
            no: x.note_no,
            dt: x.note_date,
            item: x.salary_type_name,
            note: x.descriptions,
            qty: x.quantity,
            price: x.unit_price,
            amount: x.amount
          }
        end) ++
          [
            %{
              type: "income",
              no: "session_total",
              amount: x.addition_amount
            }
          ]

      bon =
        Enum.map(x.bonuses, fn x ->
          %{
            type: "bonus",
            no: x.note_no,
            dt: x.note_date,
            item: x.salary_type_name,
            note: x.descriptions,
            qty: x.quantity,
            price: x.unit_price,
            amount: x.amount
          }
        end) ++
          [
            %{
              type: "bonus",
              no: "session_total",
              amount: x.bonus_amount
            }
          ]

      adv =
        Enum.map(x.advances, fn x ->
          %{
            type: "advance",
            no: x.slip_no,
            dt: x.slip_date,
            item: "Advance",
            note: "",
            qty: 1,
            price: Decimal.negate(x.amount),
            amount: Decimal.negate(x.amount)
          }
        end) ++
          [
            %{
              type: "advance",
              no: "session_total",
              amount: Decimal.negate(x.advance_amount)
            }
          ]

      ded =
        Enum.map(x.deductions, fn x ->
          %{
            type: "deduction",
            no: x.note_no,
            dt: x.note_date,
            item: x.salary_type_name,
            note: x.descriptions,
            qty: x.quantity,
            price: Decimal.negate(x.unit_price),
            amount: Decimal.negate(x.amount)
          }
        end) ++
          [
            %{
              type: "deduction",
              no: "session_total",
              amount: Decimal.negate(x.deduction_amount)
            }
          ] ++
          [
            %{
              type: "pay_total",
              no: "pay_total",
              amount: x.pay_slip_amount
            }
          ]

      con =
        Enum.map(x.contributions, fn x ->
          %{
            type: "contribution",
            no: x.note_no,
            dt: x.note_date,
            item: x.salary_type_name,
            note: x.descriptions,
            qty: x.quantity,
            price: x.unit_price,
            amount: x.amount
          }
        end)

      Map.merge(x, %{details: add ++ bon ++ adv ++ ded ++ con})
      |> Map.delete(:additions)
      |> Map.delete(:deductions)
      |> Map.delete(:advances)
      |> Map.delete(:bonuses)
      |> Map.delete(:contributions)
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="print-me" class="print-here">
      {pre_print_style(assigns)}
      {if(@pre_print == "false", do: full_style(assigns))}
      <%= for ps <- @pay_slips do %>
        <%= Enum.map 1..ps.chunk_number, fn n -> %>
          <div class="page">
            <div class="letter-head">
              {if(@pre_print == "true", do: "", else: letter_head_data(assigns))}
            </div>
            <div class="doctype is-size-4 has-text-weight-semibold">Pay Slip</div>
            {pay_slip_header(ps, assigns)}
            {detail_header(assigns)}
            <div class="details-body is-size-6">
              <%= for psd <- Enum.at(ps.detail_chunks, n - 1) do %>
                {pay_slip_detail(psd, assigns)}
              <% end %>
            </div>
            {if(n == ps.chunk_number,
              do: pay_slip_footer(ps, n, ps.chunk_number, assigns),
              else: pay_slip_footer("continue", n, ps.chunk_number, assigns)
            )}
            {if(@pre_print == "true", do: "", else: letter_foot(ps, assigns))}
          </div>
        <% end %>
      <% end %>
    </div>
    """
  end

  def pay_slip_detail(psd, assigns) do
    assigns = assign(assigns, :psd, psd)

    ~H"""
    <div
      :if={@psd.no != "session_total" and @psd.no != "pay_total" and @psd.type != "contribution"}
      class={"detail #{@psd.type}"}
    >
      <span class="date">
        {format_date(@psd.dt)}
      </span>
      <span class="item">
        {@psd.item} {@psd.note}
      </span>
      <span class="qty">{@psd.qty}</span>
      <span class="price">{Number.Delimit.number_to_delimited(@psd.price)}</span>
      <span class="total">
        {Number.Delimit.number_to_delimited(@psd.amount)}
      </span>
    </div>

    <div
      :if={@psd.no != "session_total" and @psd.no != "pay_total" and @psd.type == "contribution"}
      class={"detail #{@psd.type} is-italic"}
    >
      <span class="con-item">
        {@psd.item}
      </span>
      <span class="con-total">
        {Number.Delimit.number_to_delimited(@psd.amount)}
      </span>
    </div>

    <div
      :if={@psd.no == "session_total" and !Decimal.eq?(@psd.amount, 0)}
      class={"detail has-text-weight-bold session-total #{@psd.type}"}
    >
      <span class="date"></span>
      <span class="item"></span>
      <span class="qty"></span>
      <span class="price"></span>
      <span class="total">
        {Number.Delimit.number_to_delimited(@psd.amount)}
      </span>
    </div>

    <div :if={@psd.no == "pay_total"} class={"detail has-text-weight-bold pay-total #{@psd.type}"}>
      <span class="date"></span>
      <span class="item"></span>
      <span class="qty"></span>
      <span class="price">Pay Total</span>
      <span class="total">
        {Number.Delimit.number_to_delimited(@psd.amount)}
      </span>
    </div>
    """
  end

  def pay_slip_footer("continue", page, pages, assigns) do
    assigns = assign(assigns, :page, page) |> assign(:pages, pages)

    ~H"""
    <div class="descriptions">....continue....</div>
    <div class="pay_slip-footer"></div>
    <span class="page-count">{"page #{@page} of #{@pages}"}</span>
    """
  end

  def pay_slip_footer(pay_slip, page, pages, assigns) do
    assigns = assign(assigns, :page, page) |> assign(:pages, pages) |> assign(:pay_slip, pay_slip)

    ~H"""
    <div class="pay_slip-footer"></div>
    <span class="page-count">{"page #{@page} of #{@pages}"}</span>
    """
  end

  def letter_foot(ps, assigns) do
    assigns = assign(assigns, :ps, ps)

    ~H"""
    <div class="letter-foot">
      <div class="terms is-size-6">
        <div>Please read the above information carefully.</div>
        <div>Error reported after 7 days, will not be accepted.</div>
        <div class="has-text-weight-light is-italic">Issued By: {@ps.issued_by.user.email}</div>
      </div>
      <div class="sign">Approve By</div>
      <div class="sign">Reciver Signature</div>
    </div>
    """
  end

  def detail_header(assigns) do
    ~H"""
    <div class="details-header has-text-weight-bold">
      <span class="date">Date</span>
      <span class="item">Pay Items</span>
      <span class="qty">Quantity</span>
      <span class="price">Price</span>
      <span class="total">Amount</span>
    </div>
    """
  end

  def pay_slip_header(pay_slip, assigns) do
    assigns = assigns |> assign(:pay_slip, pay_slip)

    ~H"""
    <div class="pay_slip-header">
      <div class="is-size-6">TO</div>
      <div class="customer">
        <div class="is-size-4 has-text-weight-bold">{@pay_slip.employee.name}</div>
        <div class="is-size-4">{@pay_slip.employee.id_no}</div>
      </div>
      <div class="pay_slip-info">
        <div>
          Pay Date: <span class="has-text-weight-bold">{format_date(@pay_slip.slip_date)}</span>
        </div>
        <div>Slip No: <span class="has-text-weight-bold">{@pay_slip.slip_no}</span></div>
        <div>
          Pay Period:
          <span class="has-text-weight-bold">
            {@pay_slip.pay_month}/{@pay_slip.pay_year}
          </span>
        </div>
        <div>
          Pay By: <span class="has-text-weight-bold">{@pay_slip.funds_account.name}</span>
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
      .pay-slip-header { border-bottom: 0.5mm solid black; }
      .pay_slip-footer {  }
      .terms { height: 15mm; }
      .sign { padding: 3mm; border-top: 2px dotted black; width: 30%; text-align: center; float: right; margin-left: 2mm; margin-top: 15mm;}
    </style>
    """
  end

  def pre_print_style(assigns) do
    ~H"""
    <style>
      .details-body { height: <%= @detail_body_height %>mm; }
      .detail { display: flex; height: <%= @detail_height %>mm; vertical-align: middle; align-items : center;  line-height: 4mm;}
      .page { width: 210mm; min-height: 290mm; padding: 5mm; }

      @media print {
        @page { size: A4; margin: 0mm; }
        body { width: 210mm; height: 290mm; margin: 0mm; }
        html { margin: 0mm; }
        .page { padding-left: 10mm; padding-right: 10mm; page-break-after: always;} }

      .letter-head { padding-bottom: 2mm; margin-bottom: 5mm; height: 28mm;}
      .doctype { float: right; margin-top: -20mm; margin-right: 0mm; }
      .pay_slip-info { float: right; }
      .pay_slip-header { width: 100%; height: 30mm; border-bottom: 0.5mm solid black; }
      .customer { padding-left: 2mm; float: left;}
      .pay_slip-info div { text-align: right; }

      .details-header { display: flex; text-align: center; padding-bottom: 2mm; padding-top: 2mm; border-bottom: 0.5mm solid black; }

      .date { width: 23mm; text-align: left; }
      .item { width: 100mm; text-align: left; }
      .qty { width: 21mm; text-align: center; }
      .price { width: 25mm; text-align: right; }
      .total { width: 30mm; text-align: right; }

      .con-item { width: 50mm; }
      .con-total { width: 20mm; text-align: right;}

      .detail.contribution { width: 80mm; padding-left: 3mm; }

      .detail.contribution { border-bottom: 2px solid green; }

      .session-total { text-align: right; border-top: 0.5mm solid black; border-bottom: 4px double black; height: 8mm;}

      .pay-total { font-size: 1.25rem; text-align: right; border-bottom: 4px double black; height: 10mm; margin-bottom: 2mm;}

      .pay-slip-footer { min-height: 10mm; }

      .page-count { float: right; padding-top: 1mm;}
    </style>
    """
  end
end
