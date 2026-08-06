defmodule FullCircleWeb.EInvQueueLive.Index do
  @moduledoc """
  Received e-invoice work queue: Needs bill → Billed → Paid.
  """
  use FullCircleWeb, :live_view

  alias FullCircle.EInvMetas.Queue

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: gettext("E-Invoice Queue"))
     |> assign(stage: :needs_bill)
     |> assign(terms: "")
     |> assign(days: 45)
     |> assign(rows: [])
     |> assign(counts: %{all: 0, needs_bill: 0, billed: 0, paid: 0})}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    stage = parse_stage(params["stage"])
    terms = params["terms"] || ""
    days = parse_days(params["days"])

    socket =
      socket
      |> assign(stage: stage, terms: terms, days: days)
      |> reload()

    {:noreply, socket}
  end

  @impl true
  def handle_event("search", %{"terms" => terms, "days" => days}, socket) do
    {:noreply, push_patch(socket, to: queue_path(socket, socket.assigns.stage, terms, days))}
  end

  def handle_event("filter_stage", %{"stage" => stage}, socket) do
    stage = parse_stage(stage)

    {:noreply,
     push_patch(
       socket,
       to: queue_path(socket, stage, socket.assigns.terms, socket.assigns.days)
     )}
  end

  defp reload(socket) do
    com = socket.assigns.current_company
    user = socket.assigns.current_user
    opts = [stage: socket.assigns.stage, terms: socket.assigns.terms, days: socket.assigns.days]

    counts = Queue.counts(com, user, Keyword.put(opts, :stage, :all))
    rows = Queue.list(com, user, opts)

    socket
    |> assign(counts: counts)
    |> assign(rows: rows)
  end

  defp queue_path(socket, stage, terms, days) do
    ~p"/companies/#{socket.assigns.current_company.id}/e_invoice_queue?#{%{stage: stage, terms: terms, days: days}}"
  end

  defp parse_stage("billed"), do: :billed
  defp parse_stage("paid"), do: :paid
  defp parse_stage("all"), do: :all
  defp parse_stage(_), do: :needs_bill

  defp parse_days(d) when is_binary(d) do
    case Integer.parse(d) do
      {n, _} when n in [14, 30, 45, 60, 90] -> n
      _ -> 45
    end
  end

  defp parse_days(_), do: 45

  defp stage_chip_class(active, stage) do
    base = "px-3 py-1.5 rounded-full text-sm font-medium border cursor-pointer "

    if active == stage do
      base <> stage_active_class(stage)
    else
      base <> "bg-white text-gray-700 border-gray-300 hover:bg-gray-50"
    end
  end

  defp stage_active_class(:needs_bill), do: "bg-amber-500 text-white border-amber-600"
  defp stage_active_class(:billed), do: "bg-sky-600 text-white border-sky-700"
  defp stage_active_class(:paid), do: "bg-emerald-600 text-white border-emerald-700"
  defp stage_active_class(:all), do: "bg-gray-800 text-white border-gray-900"
  defp stage_active_class(_), do: "bg-gray-800 text-white border-gray-900"

  defp row_stage_badge(:needs_bill), do: "bg-amber-100 text-amber-900"
  defp row_stage_badge(:billed), do: "bg-sky-100 text-sky-900"
  defp row_stage_badge(:paid), do: "bg-emerald-100 text-emerald-900"
  defp row_stage_badge(_), do: "bg-gray-100 text-gray-800"

  defp blocker_label(:no_contact), do: gettext("No contact match")
  defp blocker_label(:name_match), do: gettext("Contact by name only")
  defp blocker_label(_), do: nil

  defp format_dt(nil), do: "—"

  defp format_dt(%DateTime{} = dt) do
    Calendar.strftime(dt, "%d/%m/%Y")
  end

  defp format_dt(%NaiveDateTime{} = dt) do
    dt |> NaiveDateTime.to_date() |> Calendar.strftime("%d/%m/%Y")
  end

  defp format_money(nil), do: "—"

  defp format_money(%Decimal{} = d) do
    :erlang.float_to_binary(Decimal.to_float(d), decimals: 2)
  end

  defp format_money(n) when is_number(n), do: :erlang.float_to_binary(n * 1.0, decimals: 2)
  defp format_money(_), do: "—"

  defp einvoice_json(row) do
    # Minimal payload for PurInvoice/Payment new?obj= prefill (same fields Prefill needs)
    %{
      uuid: row.uuid,
      internalId: row.internal_id,
      supplierName: row.supplier_name,
      supplierTIN: row.supplier_tin,
      issuerID: row.supplier_id,
      issuerTIN: row.supplier_tin,
      totalPayableAmount: row.amount,
      totalNetAmount: row.amount,
      typeName: row.type_name,
      status: row.status,
      longId: row.long_id,
      documentCurrency: row.currency,
      dateTimeIssued: row.issued_at,
      dateTimeReceived: row.received_at
    }
    |> Jason.encode!()
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto w-11/12 max-w-6xl">
      <div class="flex flex-wrap items-center justify-between gap-2 mb-4">
        <p class="text-3xl font-medium">{@page_title}</p>
        <div class="flex gap-2">
          <.link
            navigate={~p"/companies/#{@current_company.id}/e_invoices"}
            class="button blue"
          >
            {gettext("Full E-Invoice list")}
          </.link>
        </div>
      </div>

      <p class="text-sm text-gray-600 mb-4">
        {gettext(
          "Received supplier invoices (Valid). Stage: Needs bill → Billed (PurInvoice) → Paid (Payment)."
        )}
      </p>

      <div class="flex flex-wrap gap-2 mb-4">
        <button
          type="button"
          phx-click="filter_stage"
          phx-value-stage="needs_bill"
          class={stage_chip_class(@stage, :needs_bill)}
        >
          {gettext("Needs bill")} ({@counts.needs_bill})
        </button>
        <button
          type="button"
          phx-click="filter_stage"
          phx-value-stage="billed"
          class={stage_chip_class(@stage, :billed)}
        >
          {gettext("Billed")} ({@counts.billed})
        </button>
        <button
          type="button"
          phx-click="filter_stage"
          phx-value-stage="paid"
          class={stage_chip_class(@stage, :paid)}
        >
          {gettext("Paid")} ({@counts.paid})
        </button>
        <button
          type="button"
          phx-click="filter_stage"
          phx-value-stage="all"
          class={stage_chip_class(@stage, :all)}
        >
          {gettext("All")} ({@counts.all})
        </button>
      </div>

      <form phx-submit="search" class="mb-4 flex flex-wrap gap-2 items-end">
        <div>
          <label class="block text-xs text-gray-500">{gettext("Search")}</label>
          <input
            type="search"
            name="terms"
            value={@terms}
            placeholder={gettext("Supplier, TIN, doc no…")}
            class="border rounded px-2 py-1 w-56"
          />
        </div>
        <div>
          <label class="block text-xs text-gray-500">{gettext("Last days")}</label>
          <select name="days" class="border rounded px-2 py-1">
            <option value="14" selected={@days == 14}>14</option>
            <option value="30" selected={@days == 30}>30</option>
            <option value="45" selected={@days == 45}>45</option>
            <option value="60" selected={@days == 60}>60</option>
            <option value="90" selected={@days == 90}>90</option>
          </select>
        </div>
        <button type="submit" class="button blue">{gettext("Filter")}</button>
      </form>

      <div class="overflow-x-auto rounded border border-gray-200 bg-white shadow-sm">
        <table class="w-full text-sm">
          <thead class="bg-gray-100 text-left text-xs uppercase text-gray-600">
            <tr>
              <th class="p-2">{gettext("Stage")}</th>
              <th class="p-2">{gettext("Issued")}</th>
              <th class="p-2">{gettext("Supplier")}</th>
              <th class="p-2">{gettext("Internal ID")}</th>
              <th class="p-2 text-right">{gettext("Amount")}</th>
              <th class="p-2">{gettext("Local docs")}</th>
              <th class="p-2">{gettext("Blockers")}</th>
              <th class="p-2">{gettext("Actions")}</th>
            </tr>
          </thead>
          <tbody>
            <tr :if={@rows == []}>
              <td colspan="8" class="p-6 text-center text-gray-500">
                {gettext("No e-invoices in this stage / window.")}
              </td>
            </tr>
            <tr
              :for={row <- @rows}
              class="border-t border-gray-100 hover:bg-gray-50 align-top"
            >
              <td class="p-2">
                <span class={"inline-block rounded px-2 py-0.5 text-xs font-medium #{row_stage_badge(row.stage)}"}>
                  {Queue.stage_label(row.stage)}
                </span>
              </td>
              <td class="p-2 whitespace-nowrap">{format_dt(row.issued_at)}</td>
              <td class="p-2">
                <div class="font-medium">{row.supplier_name || "—"}</div>
                <div class="text-xs text-gray-500">{row.supplier_tin}</div>
                <div :if={row.contact_name} class="text-xs text-gray-600">
                  → {row.contact_name}
                </div>
              </td>
              <td class="p-2 font-mono text-xs">{row.internal_id || "—"}</td>
              <td class="p-2 text-right tabular-nums">
                <div class="whitespace-nowrap font-medium">
                  <span class="text-xs text-gray-500 font-normal">{row.currency}</span>
                  {format_money(row.amount)}
                </div>
              </td>
              <td class="p-2 text-xs">
                <div :if={row.pur_invoice_no}>
                  PI:
                  <.link
                    class="text-blue-600 underline"
                    navigate={
                      ~p"/companies/#{@current_company.id}/PurInvoice/#{row.pur_invoice_id}/edit"
                    }
                  >
                    {row.pur_invoice_no}
                  </.link>
                </div>
                <div :if={row.payment_no}>
                  PV:
                  <.link
                    class="text-blue-600 underline"
                    navigate={
                      ~p"/companies/#{@current_company.id}/Payment/#{row.payment_id}/edit"
                    }
                  >
                    {row.payment_no}
                  </.link>
                </div>
                <div :if={is_nil(row.pur_invoice_id) and is_nil(row.payment_id)} class="text-gray-400">
                  —
                </div>
              </td>
              <td class="p-2">
                <span
                  :if={row.blocker}
                  class="inline-block rounded bg-rose-100 text-rose-800 text-xs px-2 py-0.5"
                >
                  {blocker_label(row.blocker)}
                </span>
              </td>
              <td class="p-2">
                <div class="flex flex-wrap gap-1">
                  <.link
                    :if={
                      row.stage == :needs_bill and
                        FullCircle.Authorization.can?(
                          @current_user,
                          :create_pur_invoice,
                          @current_company
                        )
                    }
                    target="_blank"
                    navigate={
                      ~p"/companies/#{@current_company.id}/PurInvoice/new?obj=#{einvoice_json(row)}"
                    }
                    class="blue button text-xs"
                  >
                    {gettext("New Pur Invoice")}
                  </.link>
                  <.link
                    :if={
                      row.stage in [:needs_bill, :billed] and
                        FullCircle.Authorization.can?(
                          @current_user,
                          :create_payment,
                          @current_company
                        )
                    }
                    target="_blank"
                    navigate={
                      ~p"/companies/#{@current_company.id}/Payment/new?obj=#{einvoice_json(row)}"
                    }
                    class="teal button text-xs"
                  >
                    {gettext("New Payment")}
                  </.link>
                  <.link
                    :if={row.pur_invoice_id}
                    navigate={
                      ~p"/companies/#{@current_company.id}/PurInvoice/#{row.pur_invoice_id}/edit"
                    }
                    class="gray button text-xs"
                  >
                    {gettext("Open bill")}
                  </.link>
                  <.link
                    :if={row.payment_id}
                    navigate={
                      ~p"/companies/#{@current_company.id}/Payment/#{row.payment_id}/edit"
                    }
                    class="gray button text-xs"
                  >
                    {gettext("Open payment")}
                  </.link>
                </div>
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <p class="mt-3 text-xs text-gray-500">
        {gettext("Tip: Sync e-invoices from the full listing first if the queue looks empty.")}
        ·
        <.link
          class="underline"
          navigate={~p"/companies/#{@current_company.id}/e_invoices?search[direction]=Received"}
        >
          {gettext("Open received listing")}
        </.link>
      </p>
    </div>
    """
  end
end
