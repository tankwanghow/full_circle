defmodule FullCircleWeb.ChequeLive.ReturnChequePrint do
  use FullCircleWeb, :live_view

  import FullCircleWeb.Helpers
  alias FullCircle.Cheque

  @impl true
  def mount(%{"id" => id, "pre_print" => pre_print}, _session, socket) do
    ids = [id]
    {:ok, socket |> assign(:pre_print, pre_print) |> set_page_defaults() |> fill_journals(ids)}
  end

  @impl true
  def mount(%{"ids" => ids, "pre_print" => pre_print}, _, socket) do
    ids = String.split(ids, ",")
    {:ok, socket |> assign(:pre_print, pre_print) |> set_page_defaults() |> fill_journals(ids)}
  end

  defp set_page_defaults(socket) do
    socket
    |> assign(:detail_body_height, 20)
    |> assign(:detail_height, 9)
    |> assign(:company, FullCircle.Sys.get_company!(socket.assigns.current_company.id))
  end

  defp fill_journals(socket, ids) do
    chunk = (socket.assigns.detail_body_height / socket.assigns.detail_height) |> floor

    rtqs =
      Cheque.get_print_return_cheque!(
        ids,
        socket.assigns.current_company,
        socket.assigns.current_user
      )
      |> Enum.map(fn rtq ->
        rtq
        |> Map.merge(%{
          chunk_number: Enum.chunk_every([rtq.cheque], chunk) |> Enum.count()
        })
        |> Map.merge(%{
          detail_chunks: Enum.chunk_every([rtq.cheque], chunk)
        })
      end)

    socket
    |> assign(:rtqs, rtqs)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="print-me" class="print-here">
      <%= pre_print_style(assigns) %>
      <%= if(@pre_print == "false", do: full_style(assigns)) %>
      <%= for rtq <- @rtqs do %>
        <%= Enum.map 1..rtq.chunk_number, fn n -> %>
          <div class="page">
            <div class="letter-head">
              <%= if(@pre_print == "true", do: "", else: letter_head_data(assigns)) %>
            </div>
            <div class="doctype is-size-4 has-text-weight-semibold">RETURN CHEQUE NOTICE</div>
            <%= header(rtq, assigns) %>
            <%= detail_header(assigns) %>
            <div class="details-body is-size-6">
              <%= for chq <- Enum.at(rtq.detail_chunks, n - 1) do %>
                <%= detail(chq, assigns) %>
              <% end %>
            </div>
            <%= if(n == rtq.chunk_number,
              do: footer(rtq, n, rtq.chunk_number, assigns),
              else: footer("continue", n, rtq.chunk_number, assigns)
            ) %>
            <%= if(@pre_print == "true", do: "", else: letter_foot(assigns)) %>
          </div>
        <% end %>
      <% end %>
    </div>
    """
  end

  def detail(chq, assigns) do
    assigns = assign(assigns, :chq, chq)

    ~H"""
    <div class="detail is-size-5">
      <div class="bank"><%= @chq.bank %></div>
      <div class="chq_no"><%= @chq.cheque_no %></div>
      <div class="due_date"><%= @chq.due_date %></div>
      <div class="city"><%= @chq.city %></div>
      <div class="state"><%= @chq.state %></div>
      <div class="amount"><%= Number.Delimit.number_to_delimited(@chq.amount) %></div>
    </div>
    """
  end

  def footer("continue", page, pages, assigns) do
    assigns = assign(assigns, :page, page) |> assign(:pages, pages)

    ~H"""
    <div class="footer">
      <div class="descriptions">....continue....</div>
    </div>
    <span class="page-count"><%= "page #{@page} of #{@pages}" %></span>
    """
  end

  def footer(rtnq, page, pages, assigns) do
    assigns = assign(assigns, :page, page) |> assign(:pages, pages) |> assign(:rtnq, rtnq)

    ~H"""
    <div class="footer">
      <div class="empty-footer" />
    </div>
    <span class="page-count"><%= "page #{@page} of #{@pages}" %></span>
    """
  end

  def letter_foot(assigns) do
    ~H"""
    <div class="letter-foot">
      <div class="sign">Entry By</div>
      <div class="sign">Approved By</div>
    </div>
    """
  end

  def detail_header(assigns) do
    ~H"""
    <div class="details-header has-text-weight-bold is-size-5">
      <div class="bank">Bank</div>
      <div class="chq_no">Cheque No</div>
      <div class="due_date">Due Date</div>
      <div class="city">City</div>
      <div class="state">State</div>
      <div class="amount">Amount</div>
    </div>
    """
  end

  def header(rtq, assigns) do
    assigns = assigns |> assign(:rtq, rtq)

    ~H"""
    <div class="rtq-header">
      <div class="is-size-6">Return Cheque To</div>
      <div class="customer">
        <div class="is-size-5 has-text-weight-semibold"><%= @rtq.cheque_owner.name %></div>
        <div><%= @rtq.cheque_owner.address1 %></div>
        <div><%= @rtq.cheque_owner.address2 %></div>
        <div>
          <%= Enum.join(
            [
              @rtq.cheque_owner.city,
              @rtq.cheque_owner.zipcode,
              @rtq.cheque_owner.state,
              @rtq.cheque_owner.country
            ],
            " "
          ) %>
        </div>
        <%= @rtq.cheque_owner.reg_no %>
      </div>
      <div class="rtq-info is-size-5">
        <div>
          Return Date:
          <span class="has-text-weight-semibold"><%= format_date(@rtq.return_date) %></span>
        </div>
        <div>
          Return No: <span class="has-text-weight-semibold"><%= @rtq.return_no %></span>
        </div>
        <div>
          Reason: <span class="has-text-weight-semibold"><%= @rtq.return_reason %></span>
        </div>
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
      .letter-foot { border-top: 0.5mm solid black; }
      .header { border-bottom: 0.5mm solid black; }
      .footer {  }
      .terms { height: 15mm; }
      .sign { padding: 3mm; border-top: 2px dotted black; width: 30%; text-align: center; float: left; margin-left: 2mm; margin-top: 15mm;}
    </style>
    """
  end

  def pre_print_style(assigns) do
    ~H"""
    <style>
      .details-body { height: <%= @detail_body_height %>mm; }
      .detail { display: flex; height: <%= @detail_height %>mm; vertical-align: middle; text-align : center;}
      .page { width: 210mm; min-height: 145mm; padding: 5mm; }

      @media print {
        @page { size: A5; margin: 0mm; }
        body { width: 210mm; height: 145mm; margin: 0mm; }
        html { margin: 0mm; }
        .page { padding: 5mm; page-break-after: always; } }

      .letter-head { padding-bottom: 2mm; margin-bottom: 2mm; height: 28mm;}
      .doctype { float: right; margin-top: -20mm; margin-right: 0mm; }
      .rtq-info { float: right; }
      .rtq-header { width: 100%; height: 40mm; border-bottom: 0.5mm solid black; }
      .customer { padding-left: 2mm; float: left;}
      .rtq-info div { margin-bottom: 2mm; text-align: right; }
      .details-header { display: flex; text-align: center; padding-bottom: 2mm; padding-top: 2mm; border-bottom: 0.5mm solid black; }

      .bank { width: 16%; }
      .due_date { width: 16%; }
      .chq_no { width: 16%; }
      .city { width: 16%; }
      .state { width: 16%; }
      .amount { width: 20%; }

      .footer { margin-bottom: 1mm; padding: 1mm 0 1mm 0; }

      .descriptions { }
      .empty-footer { min-height: 19px; }
      .page-count { float: right; padding-top: 5px;}
    </style>
    """
  end
end
