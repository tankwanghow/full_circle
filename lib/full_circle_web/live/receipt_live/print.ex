defmodule FullCircleWeb.ReceiptLive.Print do
  use FullCircleWeb, :live_view

  import FullCircleWeb.Helpers
  alias FullCircle.{ReceiveFund, Accounting}

  @impl true
  def mount(%{"id" => id, "pre_print" => pre_print}, _session, socket) do
    ids = [id]

    {:ok,
     socket
     |> assign(page_title: gettext("Print"))
     |> assign(:pre_print, pre_print)
     |> set_page_defaults()
     |> fill_receipts(ids)}
  end

  @impl true
  def mount(%{"ids" => ids, "pre_print" => pre_print}, _, socket) do
    ids = String.split(ids, ",")

    {:ok,
     socket
     |> assign(page_title: gettext("Print"))
     |> assign(:pre_print, pre_print)
     |> set_page_defaults()
     |> fill_receipts(ids)}
  end

  defp set_page_defaults(socket) do
    socket
    |> assign(:detail_body_height, 160)
    |> assign(:detail_height, 9)
    |> assign(:company, FullCircle.Sys.get_company!(socket.assigns.current_company.id))
  end

  defp fill_receipts(socket, ids) do
    chunk = (socket.assigns.detail_body_height / socket.assigns.detail_height) |> floor

    receipts =
      ReceiveFund.get_print_receipts!(
        ids,
        socket.assigns.current_company,
        socket.assigns.current_user
      )
      |> Enum.map(fn r ->
        fill_head_foot_for(r, :receipt_details, "detail_head", "detail_foot")
      end)
      |> Enum.map(fn r ->
        fill_head_foot_for(r, :received_cheques, "cheque_head", "cheque_foot")
      end)
      |> Enum.map(fn r ->
        fill_head_foot_for(r, :transaction_matchers, "match_head", "match_foot")
      end)
      |> Enum.map(fn receipt ->
        receipt
        |> Map.merge(%{
          chunk_number:
            Enum.chunk_every(
              receipt.receipt_details ++
                receipt.transaction_matchers ++
                receipt.received_cheques ++
                [%{__struct__: "funds_head"}, receipt, %{__struct__: "funds_foot"}],
              chunk
            )
            |> Enum.count()
        })
        |> Map.merge(%{
          all_chunks:
            Enum.chunk_every(
              receipt.receipt_details ++
                receipt.transaction_matchers ++
                receipt.received_cheques ++
                [%{__struct__: "funds_head"}, receipt, %{__struct__: "funds_foot"}],
              chunk
            )
        })
      end)

    socket
    |> assign(:receipts, receipts)
  end

  defp fill_head_foot_for(map, list_atom, header, footer) do
    if Map.fetch!(map, list_atom) != [] do
      Map.merge(
        map,
        Map.new([
          {list_atom,
           [%{__struct__: header}] ++ Map.fetch!(map, list_atom) ++ [%{__struct__: footer}]}
        ])
      )
    else
      map
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="print-me" class="print-here">
      {pre_print_style(assigns)}
      {if(@pre_print == "false", do: full_style(assigns))}
      <%= for receipt  <- @receipts do %>
        <%= Enum.map 1..receipt.chunk_number, fn n -> %>
          <div class="page">
            <div class="letter-head">
              {if(@pre_print == "true", do: "", else: letter_head(assigns))}
            </div>

            <div :if={@pre_print == "false"} class="qrcode">
              <% {_, qrcode} = FullCircle.Helpers.e_invoice_validation_url_qrcode(receipt) %>
              {qrcode |> raw}
            </div>

            {receipt_header(receipt, assigns)}

            <div class="details-body is-size-6">
              <%= for recd <- Enum.at(receipt.all_chunks, n - 1) do %>
                {detail_header(recd, assigns)}
                {detail_footer(recd, receipt, assigns)}
                {receipt_detail(recd, assigns)}
                {match_tran_header(recd, assigns)}
                {match_tran_footer(recd, receipt, assigns)}
                {receipt_match_tran(recd, assigns)}
                {cheque_header(recd, assigns)}
                {cheque_footer(recd, receipt, assigns)}
                {receipt_cheque(recd, assigns)}
                {funds_header(recd, receipt, assigns)}
                {funds_footer(recd, receipt, assigns)}
                {receipt_funds(recd, assigns)}
              <% end %>
            </div>

            {if(n == receipt.chunk_number,
              do: receipt_footer(receipt, n, receipt.chunk_number, assigns),
              else: receipt_footer("continue", n, receipt.chunk_number, assigns)
            )}
            <div class="letter-foot">
              {if(@pre_print == "true", do: "", else: letter_foot(receipt, assigns))}
            </div>
          </div>
        <% end %>
      <% end %>
    </div>
    """
  end

  def receipt_funds(recd, assigns) do
    assigns = assign(assigns, :recd, recd)

    ~H"""
    <div
      :if={@recd.__struct__ == ReceiveFund.Receipt and Decimal.gt?(@recd.funds_amount, 0)}
      class="funds"
    >
      <div class="account">To {@recd.funds_account.name}</div>
      <div class="amount">
        {Number.Delimit.number_to_delimited(@recd.funds_amount)}
      </div>
    </div>
    """
  end

  def receipt_cheque(recd, assigns) do
    assigns = assign(assigns, :recd, recd)

    ~H"""
    <div :if={@recd.__struct__ == ReceiveFund.ReceivedCheque} class="cheque">
      <div class="bank">{@recd.bank}</div>
      <div class="city">{@recd.city}</div>
      <div class="state">{@recd.state}</div>
      <div class="chqno">{@recd.cheque_no}</div>
      <div class="duedate">{format_date(@recd.due_date)}</div>
      <div class="chqamt">{Number.Delimit.number_to_delimited(@recd.amount)}</div>
    </div>
    """
  end

  def receipt_match_tran(recd, assigns) do
    assigns = assign(assigns, :recd, recd)

    ~H"""
    <div :if={@recd.__struct__ == Accounting.TransactionMatcher} class="matched">
      <div class="date">{format_date(@recd.t_doc_date)}</div>
      <div class="matchdoctype">{@recd.t_doc_type}</div>
      <div class="docno">{@recd.t_doc_no}</div>
      <div class="amount">{@recd.amount |> Number.Delimit.number_to_delimited()}</div>
      <div class="balance">{@recd.balance |> Number.Delimit.number_to_delimited()}</div>
      <div class="matchamt">
        {Number.Delimit.number_to_delimited(@recd.match_amount |> Decimal.abs())}
      </div>
    </div>
    """
  end

  def receipt_detail(recd, assigns) do
    assigns = assign(assigns, :recd, recd)

    ~H"""
    <div :if={@recd.__struct__ == ReceiveFund.ReceiptDetail} class="detail">
      <div class="particular">
        <div>
          {if(@recd.good_name != "Note", do: @recd.good_name, else: "")}
          {if(Decimal.gt?(@recd.package_qty, 0), do: " - #{@recd.package_qty}", else: "")}
          {if(!is_nil(@recd.package_name) and @recd.package_name != "-",
            do: "(#{@recd.package_name})",
            else: ""
          )}
        </div>
        <div class={if(@recd.good_name != "Note", do: "is-size-7", else: "")}>
          {if(@recd.descriptions != "" and !is_nil(@recd.descriptions),
            do: "#{@recd.descriptions}",
            else: ""
          )}
        </div>
      </div>
      <div class="qty">
        {if Decimal.integer?(@recd.quantity),
          do: Decimal.to_integer(@recd.quantity),
          else: @recd.quantity} {if @recd.unit == "-", do: "", else: @recd.unit}
      </div>
      <div class="price">{format_unit_price(@recd.unit_price)}</div>
      <div class="disc">
        {if(Decimal.eq?(@recd.discount, 0),
          do: "-",
          else: Number.Delimit.number_to_delimited(@recd.discount)
        )}
      </div>
      <div class="total">
        <div>{Number.Delimit.number_to_delimited(@recd.good_amount)}</div>

        <%= if Decimal.gt?(@recd.tax_amount, 0) do %>
          <div class="is-size-7">
            {@recd.tax_code_name}
            {Number.Percentage.number_to_percentage(Decimal.mult(@recd.tax_rate, 100))}
            {Number.Delimit.number_to_delimited(@recd.tax_amount)}
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  def match_tran_footer(recd, receipt, assigns) do
    assigns = assigns |> assign(:receipt, receipt) |> assign(:recd, recd)

    ~H"""
    <div :if={@recd.__struct__ == "match_foot"} class="details-footer">
      <span class="has-text-weight-semibold">
        Matched Amount: {Number.Delimit.number_to_delimited(
          @receipt.matched_amount
          |> Decimal.abs()
        )}
      </span>
    </div>
    """
  end

  def detail_footer(recd, receipt, assigns) do
    assigns = assigns |> assign(:receipt, receipt) |> assign(:recd, recd)

    ~H"""
    <div :if={@recd.__struct__ == "detail_foot"} class="details-footer">
      <span>
        Particular Amount: {Number.Delimit.number_to_delimited(@receipt.receipt_good_amount)}
      </span>
      <span>
        Tax Amount: {Number.Delimit.number_to_delimited(@receipt.receipt_tax_amount)}
      </span>
      <span class="has-text-weight-semibold">
        Detail Amount: {Number.Delimit.number_to_delimited(@receipt.receipt_detail_amount)}
      </span>
    </div>
    """
  end

  def funds_footer(recd, receipt, assigns) do
    assigns = assigns |> assign(:receipt, receipt) |> assign(:recd, recd)

    ~H"""
    <div
      :if={@recd.__struct__ == "funds_foot" and Decimal.gt?(@receipt.funds_amount, 0)}
      class="details-footer"
    >
      <span class="has-text-weight-semibold">
        Funds Amount: {Number.Delimit.number_to_delimited(@receipt.funds_amount)}
      </span>
    </div>
    """
  end

  def cheque_footer(recd, receipt, assigns) do
    assigns = assigns |> assign(:receipt, receipt) |> assign(:recd, recd)

    ~H"""
    <div :if={@recd.__struct__ == "cheque_foot"} class="details-footer">
      <span class="has-text-weight-semibold">
        Cheques Amount: {Number.Delimit.number_to_delimited(@receipt.cheques_amount)}
      </span>
    </div>
    """
  end

  def receipt_footer("continue", page, pages, assigns) do
    assigns = assign(assigns, :page, page) |> assign(:pages, pages)

    ~H"""
    <div class="receipt-footer">
      <div class="continue">....continue....</div>
      <div class="empty-footer" />
    </div>
    <span class="page-count">{"page #{@page} of #{@pages}"}</span>
    """
  end

  def receipt_footer(receipt, page, pages, assigns) do
    assigns = assign(assigns, :page, page) |> assign(:pages, pages) |> assign(:receipt, receipt)

    ~H"""
    <div class="receipt-footer">
      <div class="descriptions">{@receipt.descriptions}</div>
      <div class="receipt-amount has-text-weight-bold">
        Receipt Amount: {Number.Delimit.number_to_delimited(
          Decimal.add(@receipt.cheques_amount, @receipt.funds_amount)
        )}
      </div>
    </div>
    <span class="page-count">{"page #{@page} of #{@pages}"}</span>
    """
  end

  def letter_foot(recd, assigns) do
    assigns = assigns |> assign(:recd, recd)

    ~H"""
    <div class="terms is-size-7">
      <div>This receipt is only valid subject to cheque or cheques honoured by the bank.</div>
      <div class="has-text-weight-light is-italic is-size-6">
        Issued By: {@recd.issued_by.user.email}
      </div>
    </div>
    <div class="sign">Collector Signature</div>
    <div class="sign">Manager/Cashier Signature</div>
    """
  end

  def detail_header(recd, assigns) do
    assigns = assigns |> assign(:recd, recd)

    ~H"""
    <div :if={@recd.__struct__ == "detail_head"} class="details-header has-text-weight-semibold">
      <div class="particular">Particulars</div>
      <div class="qty">Quantity</div>
      <div class="price">Price</div>
      <div class="disc">Discount</div>
      <div class="total">Total & Tax</div>
    </div>
    """
  end

  def cheque_header(recd, assigns) do
    assigns = assigns |> assign(:recd, recd)

    ~H"""
    <div
      :if={@recd.__struct__ == "cheque_head"}
      class="cheque has-text-weight-semibold details-header"
    >
      <div class="bank">Bank</div>
      <div class="city">City</div>
      <div class="state">State</div>
      <div class="chqno">Chq No</div>
      <div class="duedate">Chq Date</div>
      <div class="chqamt ">Amount</div>
    </div>
    """
  end

  def funds_header(recd, receipt, assigns) do
    assigns = assigns |> assign(:recd, recd) |> assign(:receipt, receipt)

    ~H"""
    """
  end

  def match_tran_header(recd, assigns) do
    assigns = assigns |> assign(:recd, recd)

    ~H"""
    <div
      :if={@recd.__struct__ == "match_head"}
      class="matched has-text-weight-semibold details-header"
    >
      <div class="date">Date</div>
      <div class="matchdoctype">Doc Type</div>
      <div class="docno">Doc No</div>
      <div class="amount">Amount</div>
      <div class="balance">Balance</div>
      <div class="matchamt ">Match Amount</div>
    </div>
    """
  end

  def receipt_header(receipt, assigns) do
    assigns = assigns |> assign(:receipt, receipt)

    ~H"""
    <div class="receipt-header">
      <div class="is-size-6">Receive From</div>
      <div class="customer">
        <div class="is-size-5 has-text-weight-semibold">{@receipt.contact.name}</div>
        <div>{@receipt.contact.address1}</div>
        <div>{@receipt.contact.address2}</div>
        <div>
          {Enum.join(
            [
              @receipt.contact.city,
              @receipt.contact.zipcode,
              @receipt.contact.state,
              @receipt.contact.country
            ],
            " "
          )}
        </div>
        {@receipt.contact.reg_no}
      </div>
      <div class="receipt-info">
        <div class="is-size-4 has-text-weight-semibold">RECEIPT</div>
        <div>
          Receipt Date:
          <span class="has-text-weight-semibold">{format_date(@receipt.receipt_date)}</span>
        </div>
        <div>
          Receipt No: <span class="has-text-weight-semibold">{@receipt.receipt_no}</span>
        </div>
      </div>
    </div>
    """
  end

  def letter_head(assigns) do
    ~H"""
    <div class="is-size-3 has-text-weight-semibold">{@company.name}</div>
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
      .receipt-header { border-bottom: 0.5mm solid black; }
      .receipt-footer { display: flex; }
      .terms { height: 15mm; }
      .sign { padding: 3mm; border-top: 2px dotted black; width: 30%; text-align: center; float: right; margin-left: 2mm; margin-top: 8mm;}
    </style>
    """
  end

  def pre_print_style(assigns) do
    ~H"""
    <style>
      .details-body { min-height: <%= @detail_body_height %>mm; max-height: <%= @detail_body_height %>mm; }
      .details-body div { vertical-align: top; }
      .detail { display: flex; height: <%= @detail_height %>mm; vertical-align: middle; align-items: center; }
      .cheque { display: flex; height: <%= @detail_height %>mm; vertical-align: middle;  align-items: center; }
      .funds { display: flex; height: <%= @detail_height %>mm; vertical-align: middle;  align-items: center; }
      .matched { display: flex; height: <%= @detail_height %>mm; vertical-align: middle;  align-items: center; }
      .page { width: 210mm; min-height: 290mm; padding: 5mm; }

      @media print {
        @page { size: A4; margin: 0mm; }
        body { width: 210mm; height: 290mm; margin: 0mm; }
        html { margin: 0mm; }
        .page { padding: 5mm; page-break-after: always;} }

      .letter-head { padding-bottom: 2mm; margin-bottom: 2mm; height: 28mm;}
      .letter-foot { padding-top: 2mm; margin-top: 2mm; height: 25mm;}

      .qrcode { float: right; margin-top: -30mm; margin-right: 5mm; vertical-align: top; }
      .receipt-info { float: right; }
      .receipt-header { width: 100%; height: 40mm; border-bottom: 0.5mm solid black; }
      .receipt-footer { display: flex; }
      .customer { padding-left: 2mm; float: left;}
      .receipt-info div { margin-bottom: 2mm; text-align: right; }
      .details-header { display: flex; padding-bottom: 1mm; padding-top: 1mm; border-bottom: 0.5mm dotted black; margin-bottom: 3px;}
      .particular { width: 80mm; text-align: left; }
      .particular div { margin-bottom: 0.5mm; }
      .qty { width: 32mm; text-align: center; }
      .price { width: 25mm; text-align: center; }
      .disc { width: 24mm; text-align: center; }
      .total { width: 45mm; text-align: right; }

      .cheque .bank { width: 17%;}
      .cheque .city {width: 21%;}
      .cheque .state {width: 20%;}
      .cheque .duedate {width: 14%;}
      .cheque .chqno {width: 10%; }
      .cheque .chqamt {width: 18%; text-align: right;}

      .matched .date {width: 14%;}
      .matched .matchdoctype {width: 16%;}
      .matched .docno {width: 16%;}
      .matched .amount {width: 18%; text-align: right;}
      .matched .balance {width: 18%; text-align: right;}
      .matched .matchamt {width: 18%; text-align: right;}

      .funds .account { width: 82.5%; }
      .funds .amount {width: 17.5%; text-align: right;}

      .details-footer { margin-bottom: 1mm; padding: 1mm 0 1mm 0; text-align: right; border-top: 1px dotted black; border-bottom: 4px double black;}
      .details-footer span { padding-left: 5mm; }
      .details-footer span span { padding-left: 0; }

      .empty-footer { mix-height: 15px; }
      .descriptions { width: 60%;}
      .receipt-amount { width: 40%; text-align: right; font-size: 1.25rem; }
      .page-count { float: right; padding-top: 15px;}
    </style>
    """
  end
end
