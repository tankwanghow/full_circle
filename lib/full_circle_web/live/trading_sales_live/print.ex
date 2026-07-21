defmodule FullCircleWeb.TradingSalesLive.Print do
  @moduledoc "Printable sales position document."
  use FullCircleWeb, :live_view

  import FullCircleWeb.Helpers
  alias FullCircle.Trading
  alias FullCircle.Authorization
  alias FullCircle.Trading.Balances

  @impl true
  def mount(%{"id" => id} = params, _session, socket) do
    company = socket.assigns.current_company
    user = socket.assigns.current_user
    pre_print = Map.get(params, "pre_print", "false")

    if Authorization.can?(user, :view_trading, company) do
      sales = Trading.get_sales_position!(id, company, user)

      {:ok,
       socket
       |> assign(page_title: gettext("Print Sales") <> " " <> (sales.title || ""))
       |> assign(:pre_print, pre_print)
       |> assign(:company, FullCircle.Sys.get_company!(company.id))
       |> assign(:sales, sales)
       |> assign(:delivered, Balances.sales_delivered(sales))
       |> assign(:undelivered, Balances.sales_undelivered(sales))}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("You are not authorised to perform this action"))
       |> push_navigate(to: ~p"/companies/#{company.id}/dashboard")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="print-me" class="print-here">
      {pre_print_style(assigns)}
      {if(@pre_print == "false", do: full_style(assigns))}
      <div class="page">
        <div class="letter-head">
          {if(@pre_print == "true", do: "", else: letter_head_data(assigns))}
        </div>
        <div class="doctype is-size-4 has-text-weight-semibold">{gettext("SALES POSITION")}</div>

        <div class="doc-header">
          <div class="left">
            <div class="is-size-6">{gettext("Customer")}</div>
            <div class="is-size-4 has-text-weight-semibold">
              {@sales.customer && @sales.customer.name}
            </div>
          </div>
          <div class="right is-size-5">
            <div>
              {gettext("Sales no")}:
              <span class="has-text-weight-semibold">{@sales.title}</span>
            </div>
            <div>
              {gettext("Status")}:
              <span class="has-text-weight-semibold">{@sales.status}</span>
            </div>
            <div>
              {gettext("Needed by")}:
              <span class="has-text-weight-semibold">
                {if @sales.available_from, do: format_date(@sales.available_from), else: "—"}
              </span>
            </div>
          </div>
        </div>

        <table class="info-table is-size-5">
          <tr>
            <td class="label">{gettext("Good")}</td>
            <td>{@sales.good && @sales.good.name}</td>
            <td class="label">{gettext("Unit")}</td>
            <td>{@sales.good && @sales.good.unit}</td>
          </tr>
          <tr>
            <td class="label">{gettext("Quantity")}</td>
            <td class="num">{format_qty(@sales.quantity)}</td>
            <td class="label">{gettext("Unit price")}</td>
            <td class="num">
              {if @sales.unit_price, do: format_qty(@sales.unit_price), else: "—"}
            </td>
          </tr>
          <tr>
            <td class="label">{gettext("Delivered")}</td>
            <td class="num">{format_qty(@delivered)}</td>
            <td class="label">{gettext("Undelivered")}</td>
            <td class="num">{format_qty(@undelivered)}</td>
          </tr>
          <tr>
            <td class="label">{gettext("Preferred supply")}</td>
            <td colspan="3">
              {(@sales.preferred_supply && @sales.preferred_supply.title) || "—"}
            </td>
          </tr>
        </table>

        <div :if={@sales.notes && @sales.notes != ""} class="notes is-size-6">
          <span class="has-text-weight-semibold">{gettext("Notes")}:</span>
          {@sales.notes}
        </div>
        <div :if={@sales.fulfilled_note && @sales.fulfilled_note != ""} class="notes is-size-6">
          <span class="has-text-weight-semibold">{gettext("Fulfilled note")}:</span>
          {@sales.fulfilled_note}
        </div>

        {if(@pre_print == "true", do: "", else: letter_foot(assigns))}
      </div>
    </div>
    """
  end

  defp format_qty(%Decimal{} = d), do: Decimal.to_string(d)
  defp format_qty(nil), do: "—"
  defp format_qty(v), do: to_string(v)

  def letter_head_data(assigns) do
    ~H"""
    <div class="is-size-3 has-text-weight-bold">{@company.name}</div>
    <div>{@company.address1}, {@company.address2}</div>
    <div>
      {Enum.join(
        Enum.reject(
          [@company.zipcode, @company.city, @company.state, @company.country],
          &(&1 in [nil, ""])
        ),
        ", "
      )}
    </div>
    <div>
      Tel: {@company.tel} RegNo: {@company.reg_no} Email: {@company.email}
    </div>
    """
  end

  def letter_foot(assigns) do
    ~H"""
    <div class="letter-foot">
      <div class="sign">{gettext("Prepared by")}</div>
      <div class="sign">{gettext("Approved by")}</div>
      <div class="sign">{gettext("Customer")}</div>
    </div>
    """
  end

  def full_style(assigns) do
    ~H"""
    <style>
      .letter-head { border-bottom: 0.5mm solid black; }
      .letter-foot { border-top: 0.5mm solid black; margin-top: 12mm; }
      .sign { padding: 3mm; border-top: 2px dotted black; width: 28%; text-align: center; float: right; margin-left: 3mm; margin-top: 18mm; }
    </style>
    """
  end

  def pre_print_style(assigns) do
    ~H"""
    <style>
      .page { width: 210mm; min-height: 148mm; padding: 8mm; }
      @media print {
        @page { size: A4; margin: 8mm; }
        body { margin: 0; }
        .page { padding: 0; page-break-after: always; }
      }
      .letter-head { padding-bottom: 2mm; margin-bottom: 3mm; height: 28mm; }
      .doctype { float: right; margin-top: -18mm; margin-right: 0; }
      .doc-header { width: 100%; min-height: 22mm; border-bottom: 0.5mm solid black; margin-bottom: 4mm; overflow: auto; }
      .doc-header .left { float: left; width: 55%; }
      .doc-header .right { float: right; text-align: right; }
      .doc-header .right div { margin-bottom: 1.5mm; }
      .info-table { width: 100%; border-collapse: collapse; margin-bottom: 4mm; }
      .info-table td { border: 0.3mm solid #333; padding: 2mm 3mm; vertical-align: top; }
      .info-table td.label { width: 18%; font-weight: 600; background: #f5f5f5; }
      .info-table td.num { text-align: right; font-variant-numeric: tabular-nums; }
      .notes { margin-top: 3mm; white-space: pre-wrap; }
    </style>
    """
  end
end
