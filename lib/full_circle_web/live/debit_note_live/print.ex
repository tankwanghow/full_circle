defmodule FullCircleWeb.DebitNoteLive.Print do
  use FullCircleWeb, :live_view

  import FullCircleWeb.Helpers
  alias FullCircle.{DebCre, Accounting}

  @impl true
  def mount(%{"id" => id, "pre_print" => pre_print}, _session, socket) do
    ids = [id]

    {:ok,
     socket
     |> assign(page_title: gettext("Print"))
     |> assign(:pre_print, pre_print)
     |> set_page_defaults()
     |> fill_debit_notes(ids)}
  end

  @impl true
  def mount(%{"ids" => ids, "pre_print" => pre_print}, _, socket) do
    ids = String.split(ids, ",")

    {:ok,
     socket
     |> assign(page_title: gettext("Print"))
     |> assign(:pre_print, pre_print)
     |> set_page_defaults()
     |> fill_debit_notes(ids)}
  end

  defp set_page_defaults(socket) do
    socket
    |> assign(:detail_body_height, 160)
    |> assign(:detail_height, 9)
    |> assign(:company, FullCircle.Sys.get_company!(socket.assigns.current_company.id))
  end

  defp fill_debit_notes(socket, ids) do
    chunk = (socket.assigns.detail_body_height / socket.assigns.detail_height) |> floor

    notes =
      DebCre.get_print_debit_notes!(
        ids,
        socket.assigns.current_company,
        socket.assigns.current_user
      )
      |> Enum.map(fn r ->
        fill_head_foot_for(r, :debit_note_details, "detail_head", "detail_foot")
      end)
      |> Enum.map(fn r ->
        fill_head_foot_for(r, :transaction_matchers, "match_head", "match_foot")
      end)
      |> Enum.map(fn note ->
        note
        |> Map.merge(%{
          chunk_number:
            Enum.chunk_every(
              note.debit_note_details ++
                note.transaction_matchers,
              chunk
            )
            |> Enum.count()
        })
        |> Map.merge(%{
          all_chunks:
            Enum.chunk_every(
              note.debit_note_details ++
                note.transaction_matchers,
              chunk
            )
        })
      end)

    socket
    |> assign(:notes, notes)
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
      <%= for note  <- @notes do %>
        <%= Enum.map 1..note.chunk_number, fn n -> %>
          <div class="page">
            <div class="letter-head">
              {if(@pre_print == "true", do: "", else: letter_head(assigns))}
            </div>

            <div :if={@pre_print == "false"} class="qrcode">
              <% {_, qrcode} = FullCircle.Helpers.e_invoice_validation_url_qrcode(note) %>
              {qrcode |> raw}
            </div>

            {note_header(note, assigns)}

            <div class="details-body is-size-6">
              <%= for recd <- Enum.at(note.all_chunks, n - 1) do %>
                {detail_header(recd, assigns)}
                {detail_footer(recd, note, assigns)}
                {note_detail(recd, assigns)}
                {match_tran_header(recd, assigns)}
                {match_tran_footer(recd, note, assigns)}
                {note_match_tran(recd, assigns)}
              <% end %>
            </div>

            {if(n == note.chunk_number,
              do: note_footer(note, n, note.chunk_number, assigns),
              else: note_footer("continue", n, note.chunk_number, assigns)
            )}
            <div class="letter-foot">
              {if(@pre_print == "true", do: "", else: letter_foot(note, assigns))}
            </div>
          </div>
        <% end %>
      <% end %>
    </div>
    """
  end

  def note_match_tran(recd, assigns) do
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

  def note_detail(recd, assigns) do
    assigns = assign(assigns, :recd, recd)

    ~H"""
    <div :if={@recd.__struct__ == DebCre.DebitNoteDetail} class="detail">
      <span class="particular">
        {@recd.descriptions}
      </span>
      <span class="qty">
        {if Decimal.integer?(@recd.quantity),
          do: Decimal.to_integer(@recd.quantity),
          else: @recd.quantity}
      </span>
      <span class="price">{format_unit_price(@recd.unit_price)}</span>
      <span class="total">
        <div>{Number.Delimit.number_to_delimited(@recd.desc_amount)}</div>
        <%= if Decimal.gt?(@recd.tax_amount, 0) do %>
          <span class="is-size-7">
            {@recd.tax_code_name}
            {Number.Percentage.number_to_percentage(Decimal.mult(@recd.tax_rate, 100))}
            {Number.Delimit.number_to_delimited(@recd.tax_amount)}
          </span>
        <% end %>
      </span>
    </div>
    """
  end

  def match_tran_footer(recd, note, assigns) do
    assigns = assigns |> assign(:note, note) |> assign(:recd, recd)

    ~H"""
    <div :if={@recd.__struct__ == "match_foot"} class="details-footer">
      <span class="has-text-weight-semibold">
        Matched Amount: {Number.Delimit.number_to_delimited(
          @note.matched_amount
          |> Decimal.abs()
        )}
      </span>
    </div>
    """
  end

  def detail_footer(recd, note, assigns) do
    assigns = assigns |> assign(:note, note) |> assign(:recd, recd)

    ~H"""
    <div :if={@recd.__struct__ == "detail_foot"} class="details-footer">
      <span>
        Desc Amount: {Number.Delimit.number_to_delimited(@note.note_desc_amount)}
      </span>
      <span>
        Tax Amount: {Number.Delimit.number_to_delimited(@note.note_tax_amount)}
      </span>
      <span class="has-text-weight-semibold">
        Detail Amount: {Number.Delimit.number_to_delimited(@note.note_amount)}
      </span>
    </div>
    """
  end

  def note_footer("continue", page, pages, assigns) do
    assigns = assign(assigns, :page, page) |> assign(:pages, pages)

    ~H"""
    <div class="footer">
      <div class="continue">....continue....</div>
      <div class="empty-footer" />
    </div>
    <span class="page-count">{"page #{@page} of #{@pages}"}</span>
    """
  end

  def note_footer(note, page, pages, assigns) do
    assigns = assign(assigns, :page, page) |> assign(:pages, pages) |> assign(:note, note)

    ~H"""
    <div class="footer">
      <div class="payment-amount has-text-weight-bold">
        Note Amount: {Number.Delimit.number_to_delimited(@note.note_amount)}
      </div>
    </div>
    <span class="page-count">{"page #{@page} of #{@pages}"}</span>
    """
  end

  def letter_foot(recd, assigns) do
    assigns = assigns |> assign(:recd, recd)

    ~H"""
    <div class="terms">
      <div class="has-text-weight-light is-italic">
        Issued By: {@recd.issued_by.user.email}
      </div>
    </div>
    <div class="sign">Entry By</div>
    <div class="sign">Approved By</div>
    """
  end

  def detail_header(recd, assigns) do
    assigns = assigns |> assign(:recd, recd)

    ~H"""
    <div :if={@recd.__struct__ == "detail_head"} class="details-header has-text-weight-semibold">
      <div class="particular">Descriptions</div>
      <div class="qty">Quantity</div>
      <div class="price">Price</div>
      <div class="total">Total & Tax</div>
    </div>
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

  def note_header(note, assigns) do
    assigns = assigns |> assign(:note, note)

    ~H"""
    <div class="header">
      <div class="is-size-6">Credit Note To</div>
      <div class="customer">
        <div class="is-size-5 has-text-weight-semibold">{@note.contact.name}</div>
        <div>{@note.contact.address1}</div>
        <div>{@note.contact.address2}</div>
        <div>
          {Enum.join(
            [
              @note.contact.city,
              @note.contact.zipcode,
              @note.contact.state,
              @note.contact.country
            ],
            " "
          )}
        </div>
        {@note.contact.reg_no}
      </div>
      <div class="payment-info">
        <div class="doctype is-size-4 has-text-weight-semibold">DEBIT NOTE</div>
        <div>
          Note Date: <span class="has-text-weight-semibold">{format_date(@note.note_date)}</span>
        </div>
        <div>
          Note No: <span class="has-text-weight-semibold">{@note.note_no}</span>
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
      .header { border-bottom: 0.5mm solid black; }
      .footer { display: flex; }
      .terms { height: 15mm; }
      .sign { padding: 3mm; border-top: 2px dotted black; width: 30%; text-align: center; float: right; margin-left: 2mm; margin-top: 10mm;}
    </style>
    """
  end

  def pre_print_style(assigns) do
    ~H"""
    <style>
      .details-body { min-height: <%= @detail_body_height %>mm; max-height: <%= @detail_body_height %>mm; }
      .detail { display: flex; height: <%= @detail_height %>mm; vertical-align: middle; align-items: center; line-height: 3.5mm;}
      .matched { display: flex; height: <%= @detail_height %>mm; vertical-align: middle;  align-items: center; }
      .page { width: 210mm; min-height: 290mm; padding: 5mm; }

      @media print {
        @page { size: A4; margin: 0mm; }
        body { width: 210mm; height: 290mm; margin: 0mm; }
        html { margin: 0mm; }
        .page { padding: 5mm; page-break-after: always;} }

      .letter-head { padding-bottom: 2mm; margin-bottom: 2mm; height: 28mm;}
      .letter-foot { padding-top: 2mm; margin-top: 2mm; height: 28mm;}

      .qrcode { float: right; margin-top: -26mm; margin-right: 5mm; vertical-align: top; }

      .header { width: 100%; height: 40mm; border-bottom: 0.5mm solid black; }
      .customer { padding-left: 2mm; float: left;}

      .payment-info div { display: block; margin-bottom: 1px; text-align: right; }

      .details-header { display: flex; padding-bottom: 1mm; padding-top: 1mm; border-bottom: 0.5mm dotted black; margin-bottom: 3px;}
      .particular { width: 90mm; text-align: left;}
      .qty { width: 32mm; text-align: center; }
      .price { width: 25mm; text-align: center; }
      .total { width: 50mm; text-align: right; }

      .matched .date {width: 14%;}
      .matched .matchdoctype {width: 16%;}
      .matched .docno {width: 16%;}
      .matched .amount {width: 18%; text-align: right;}
      .matched .balance {width: 18%; text-align: right;}
      .matched .matchamt {width: 18%; text-align: right;}

      .details-footer { margin-bottom: 1mm; padding: 1mm 0 1mm 0; text-align: right; border-top: 1px dotted black; border-bottom: 4px double black;}
      .details-footer span { padding-left: 5mm; }
      .details-footer span span { padding-left: 0; }

      .empty-footer { mix-height: 15px; }
      .payment-amount { width: 100%; text-align: right; font-size: 1.25rem; }
      .page-count { float: right; padding-top: 15px;}
    </style>
    """
  end
end
