defmodule FullCircleWeb.AdvanceLive.Print do
  use FullCircleWeb, :live_view

  import FullCircleWeb.Helpers
  alias FullCircle.HR

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
    |> assign(:detail_body_height, 10)
    |> assign(:detail_height, 9)
    |> assign(:company, FullCircle.Sys.get_company!(socket.assigns.current_company.id))
  end

  defp fill_journals(socket, ids) do
    chunk = (socket.assigns.detail_body_height / socket.assigns.detail_height) |> floor

    advs =
      HR.get_print_advances!(
        ids,
        socket.assigns.current_company,
        socket.assigns.current_user
      )
      |> Enum.map(fn adv ->
        adv
        |> Map.merge(%{
          chunk_number: Enum.chunk_every([adv], chunk) |> Enum.count()
        })
        |> Map.merge(%{
          detail_chunks: Enum.chunk_every([adv], chunk)
        })
      end)

    socket
    |> assign(:advs, advs)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="print-me" class="print-here">
      <%= pre_print_style(assigns) %>
      <%= if(@pre_print == "false", do: full_style(assigns)) %>
      <%= for adv <- @advs do %>
        <%= Enum.map 1..adv.chunk_number, fn n -> %>
          <div class="page">
            <div class="letter-head">
              <%= if(@pre_print == "true", do: "", else: letter_head_data(assigns)) %>
            </div>
            <div class="doctype is-size-4 has-text-weight-semibold">SALARY ADVANCE</div>
            <%= header(adv, assigns) %>
            <%= detail_header(assigns) %>
            <div class="details-body is-size-6">
              <%= for chq <- Enum.at(adv.detail_chunks, n - 1) do %>
                <%= detail(chq, assigns) %>
              <% end %>
            </div>
            <%= if(n == adv.chunk_number,
              do: footer(adv, n, adv.chunk_number, assigns),
              else: footer("continue", n, adv.chunk_number, assigns)
            ) %>
            <%= if(@pre_print == "true", do: "", else: letter_foot(assigns)) %>
          </div>
        <% end %>
      <% end %>
    </div>
    """
  end

  def detail(adv, assigns) do
    assigns = assign(assigns, :adv, adv)

    ~H"""
    <div class="is-size-4">
      <span><span class="has-text-weight-semibold">Pay By:</span>
        <%= @adv.funds_account.name %></span>
      <span class="amount"><span class="has-text-weight-semibold">Amount:</span>
        <%= Number.Delimit.number_to_delimited(@adv.amount) %></span>
    </div>
    """
  end

  def footer("continue", page, pages, assigns) do
    assigns = assign(assigns, :page, page) |> assign(:pages, pages)

    ~H"""
    <div class="footer">
      <div class="descriptions">....continue....</div>
    </div>
    <%!-- <span class="page-count"><%= "page #{@page} of #{@pages}" %></span> --%>
    """
  end

  def footer(adv, page, pages, assigns) do
    assigns = assign(assigns, :page, page) |> assign(:pages, pages) |> assign(:adv, adv)

    ~H"""
    <div class="footer">
      <div class="empty-footer" />
    </div>
    <%!-- <span class="page-count"><%= "page #{@page} of #{@pages}" %></span> --%>
    """
  end

  def letter_foot(assigns) do
    ~H"""
    <div class="letter-foot">
      <div class="sign">Entry By</div>
      <div class="sign">Employee Sign</div>
    </div>
    """
  end

  def detail_header(assigns) do
    ~H"""
    <div class="details-header"></div>
    """
  end

  def header(adv, assigns) do
    assigns = assigns |> assign(:adv, adv)

    ~H"""
    <div class="adv-header">
      <div class="is-size-6">To</div>
      <div class="customer">
        <div class="is-size-4 has-text-weight-semibold"><%= @adv.employee.name %></div>
        <div class="is-size-4"><%= @adv.employee.id_no %></div>
      </div>
      <div class="adv-info is-size-5">
        <div>
          Advance Date:
          <span class="has-text-weight-semibold"><%= format_date(@adv.slip_date) %></span>
        </div>
        <div>
          Advance No: <span class="has-text-weight-semibold"><%= @adv.slip_no %></span>
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
      .terms { height: 10mm; }
      .sign { padding: 3mm; border-top: 2px dotted black; width: 30%; text-align: center; float: right; margin-left: 2mm; margin-top: 15mm;}
    </style>
    """
  end

  def pre_print_style(assigns) do
    ~H"""
    <style>
      .details-body { height: <%= @detail_body_height %>mm; }
      .detail { display: flex; height: <%= @detail_height %>mm; vertical-align: middle; text-align : center;}
      .page { width: 210mm; min-height: 115mm; padding: 5mm; }

      @media print {
        @page { size: A5; margin: 0mm; }
        body { width: 210mm; height: 115mm; margin: 0mm; }
        html { margin: 0mm; }
        .page { padding: 5mm; page-break-after: always; } }

      .letter-head { padding-bottom: 2mm; margin-bottom: 2mm; height: 28mm;}
      .doctype { float: right; margin-top: -20mm; margin-right: 0mm; }
      .adv-info, .amount { float: right; }
      .adv-header { width: 100%; height: 25mm; border-bottom: 0.5mm solid black; }
      .customer { padding-left: 2mm; float: left;}
      .adv-info div { margin-bottom: 2mm; text-align: right; }
      .details-header { margin-bottom: 5mm; }

      .footer { margin-bottom: 1mm; padding: 1mm 0 1mm 0; }

      .empty-footer { min-height: 5px; }
      .page-count { float: right; padding-top: 5px;}
    </style>
    """
  end
end
