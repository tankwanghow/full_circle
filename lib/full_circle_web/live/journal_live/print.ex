defmodule FullCircleWeb.JournalLive.Print do
  use FullCircleWeb, :live_view

  import FullCircleWeb.Helpers
  alias FullCircle.JournalEntry

  @impl true
  def mount(%{"id" => id, "pre_print" => pre_print}, _session, socket) do
    ids = [id]

    {:ok,
     socket
     |> assign(page_title: gettext("Print"))
     |> assign(:pre_print, pre_print)
     |> set_page_defaults()
     |> fill_journals(ids)}
  end

  @impl true
  def mount(%{"ids" => ids, "pre_print" => pre_print}, _, socket) do
    ids = String.split(ids, ",")

    {:ok,
     socket
     |> assign(page_title: gettext("Print"))
     |> assign(:pre_print, pre_print)
     |> set_page_defaults()
     |> fill_journals(ids)}
  end

  defp set_page_defaults(socket) do
    socket
    |> assign(:detail_body_height, 55)
    |> assign(:detail_height, 15)
    |> assign(:company, FullCircle.Sys.get_company!(socket.assigns.current_company.id))
  end

  defp fill_journals(socket, ids) do
    chunk = (socket.assigns.detail_body_height / socket.assigns.detail_height) |> floor

    journals =
      JournalEntry.get_print_journals!(
        ids,
        socket.assigns.current_company,
        socket.assigns.current_user
      )
      |> Enum.map(fn journal ->
        journal
        |> Map.merge(%{
          chunk_number: Enum.chunk_every(journal.transactions, chunk) |> Enum.count()
        })
        |> Map.merge(%{
          detail_chunks: Enum.chunk_every(journal.transactions, chunk)
        })
      end)

    socket
    |> assign(:journals, journals)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="print-me" class="print-here">
      <%= pre_print_style(assigns) %>
      <%= if(@pre_print == "false", do: full_style(assigns)) %>
      <%= for journal <- @journals do %>
        <%= Enum.map 1..journal.chunk_number, fn n -> %>
          <div class="page">
            <div class="letter-head">
              <%= if(@pre_print == "true", do: "", else: letter_head_data(assigns)) %>
            </div>
            <div class="doctype is-size-4 has-text-weight-semibold">JOURNAL</div>
            <%= journal_header(journal, assigns) %>
            <%= detail_header(assigns) %>
            <div class="details-body is-size-6">
              <%= for invd <- Enum.at(journal.detail_chunks, n - 1) do %>
                <%= journal_detail(invd, assigns) %>
              <% end %>
            </div>
            <%= if(n == journal.chunk_number,
              do: journal_footer(journal, n, journal.chunk_number, assigns),
              else: journal_footer("continue", n, journal.chunk_number, assigns)
            ) %>
            <%= if(@pre_print == "true", do: "", else: letter_foot(assigns)) %>
          </div>
        <% end %>
      <% end %>
    </div>
    """
  end

  def journal_detail(txn, assigns) do
    assigns = assign(assigns, :txn, txn)

    ~H"""
    <div class="detail">
      <span class="account">
        <div>
          <%= @txn.account_name %>
        </div>
        <div class="has-text-weight-light is-size-7">
          <%= @txn.contact_name %>
        </div>
      </span>
      <span class="particulars">
        <%= @txn.particulars %>
      </span>
      <span class="amount"><%= Number.Delimit.number_to_delimited(@txn.amount) %></span>
    </div>
    """
  end

  def journal_footer("continue", page, pages, assigns) do
    assigns = assign(assigns, :page, page) |> assign(:pages, pages)

    ~H"""
    <div class="journal-footer">
      <div class="descriptions">....continue....</div>
    </div>
    <span class="page-count"><%= "page #{@page} of #{@pages}" %></span>
    """
  end

  def journal_footer(journal, page, pages, assigns) do
    assigns = assign(assigns, :page, page) |> assign(:pages, pages) |> assign(:journal, journal)

    ~H"""
    <div class="journal-footer">
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
    <div class="details-header has-text-weight-bold">
      <div class="account">Account</div>
      <div class="particulars">Particular</div>
      <div class="amount">Amount</div>
    </div>
    """
  end

  def journal_header(journal, assigns) do
    assigns = assigns |> assign(:journal, journal)

    ~H"""
    <div class="journal-header">
      <div class="journal-info is-size-5">
        <div class="journal-date">
          Journal Date:
          <span class="has-text-weight-bold"><%= format_date(@journal.journal_date) %></span>
        </div>
        <div class="journal-no">
          Journal No: <span class="has-text-weight-bold"><%= @journal.journal_no %></span>
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
      .journal-header { border-bottom: 0.5mm solid black; }
      .journal-footer {  }
      .terms { height: 15mm; }
      .sign { padding: 3mm; border-top: 2px dotted black; width: 30%; text-align: center; float: left; margin-left: 2mm; margin-top: 15mm;}
    </style>
    """
  end

  def pre_print_style(assigns) do
    ~H"""
    <style>
      .details-body { height: <%= @detail_body_height %>mm; }
      .detail { display: flex; height: <%= @detail_height %>mm; vertical-align: middle; align-items : center;}
      .page { width: 210mm; min-height: 145mm; padding: 5mm; }

      @media print {
        @page { size: A5; margin: 0mm; }
        body { width: 210mm; height: 145mm; margin: 0mm; }
        html { margin: 0mm; }
        .page { padding: 5mm; page-break-after: always; } }

      .letter-head { padding-bottom: 2mm; margin-bottom: 2mm; height: 28mm;}
      .doctype { float: right; margin-top: -20mm; margin-right: 0mm; }
      .journal-header { width: 100%; height: 10mm; border-bottom: 0.5mm solid black; }
      .journal-info { margin-bottom: 2mm; text-align: center; }
      .journal-info .journal-no { float: right; }
      .journal-info .journal-date { float: left; }
      .details-header { display: flex; text-align: center; padding-bottom: 2mm; padding-top: 2mm; border-bottom: 0.5mm solid black; }

      .particulars { width: 50%; text-align: left; }
      .account { width: 30%; text-align: left; }
      .amount { width: 20%; text-align: center; }

      .journal-footer { margin-bottom: 1mm; padding: 1mm 0 1mm 0; }

      .descriptions { }
      .empty-footer { min-height: 19px; }
      .page-count { float: right; padding-top: 5px;}
    </style>
    """
  end
end
