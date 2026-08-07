defmodule FullCircleWeb.EInvQueueLive.Index do
  @moduledoc """
  Received e-invoice work queue:

  * **Supplier bills** — Needs bill → Billed → Paid  
  * **Self-billed (sales)** — Needs invoice → Invoiced → Receipted  
  """
  use FullCircleWeb, :live_view

  alias FullCircle.EInvMetas.Queue

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: gettext("E-Invoice Queue"))
     |> assign(lane: :purchase)
     |> assign(stage: :needs_bill)
     |> assign(terms: "")
     |> assign(days: 45)
     |> assign(rows: [])
     |> assign(counts: empty_counts(:purchase))}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    lane = parse_lane(params["lane"])
    stage = parse_stage(params["stage"], lane)
    terms = params["terms"] || ""
    days = parse_days(params["days"])

    socket =
      socket
      |> assign(lane: lane, stage: stage, terms: terms, days: days)
      |> reload()

    {:noreply, socket}
  end

  @impl true
  def handle_event("search", %{"terms" => terms, "days" => days}, socket) do
    {:noreply,
     push_patch(
       socket,
       to: queue_path(socket, socket.assigns.lane, socket.assigns.stage, terms, days)
     )}
  end

  def handle_event("filter_lane", %{"lane" => lane}, socket) do
    lane = parse_lane(lane)
    stage = Queue.default_stage(lane)

    {:noreply,
     push_patch(
       socket,
       to: queue_path(socket, lane, stage, socket.assigns.terms, socket.assigns.days)
     )}
  end

  def handle_event("filter_stage", %{"stage" => stage}, socket) do
    stage = parse_stage(stage, socket.assigns.lane)

    {:noreply,
     push_patch(
       socket,
       to:
         queue_path(
           socket,
           socket.assigns.lane,
           stage,
           socket.assigns.terms,
           socket.assigns.days
         )
     )}
  end

  defp reload(socket) do
    com = socket.assigns.current_company
    user = socket.assigns.current_user

    opts = [
      lane: socket.assigns.lane,
      stage: socket.assigns.stage,
      terms: socket.assigns.terms,
      days: socket.assigns.days
    ]

    counts = Queue.counts(com, user, Keyword.put(opts, :stage, :all))
    rows = Queue.list(com, user, opts)

    socket
    |> assign(counts: counts)
    |> assign(rows: rows)
  end

  defp queue_path(socket, lane, stage, terms, days) do
    ~p"/companies/#{socket.assigns.current_company.id}/e_invoice_queue?#{%{lane: lane, stage: stage, terms: terms, days: days}}"
  end

  defp parse_lane("sales"), do: :sales
  defp parse_lane("all"), do: :all
  defp parse_lane(_), do: :purchase

  defp parse_stage(stage, lane) when is_binary(stage) do
    atom = String.to_existing_atom(stage)
    allowed = [:all | Queue.stages_for(lane)]
    if atom in allowed, do: atom, else: Queue.default_stage(lane)
  rescue
    ArgumentError -> Queue.default_stage(lane)
  end

  defp parse_stage(_, lane), do: Queue.default_stage(lane)

  defp parse_days(d) when is_binary(d) do
    case Integer.parse(d) do
      {n, _} when n in [14, 30, 45, 60, 90] -> n
      _ -> 45
    end
  end

  defp parse_days(_), do: 45

  defp empty_counts(lane) do
    Enum.reduce(Queue.stages_for(lane), %{all: 0}, fn s, acc -> Map.put(acc, s, 0) end)
  end

  defp chip_class(active, key, active_class) do
    base = "px-3 py-1.5 rounded-full text-sm font-medium border cursor-pointer "

    if active == key do
      base <> active_class
    else
      base <> "bg-white text-gray-700 border-gray-300 hover:bg-gray-50"
    end
  end

  defp stage_active_class(:needs_bill), do: "bg-amber-500 text-white border-amber-600"
  defp stage_active_class(:needs_invoice), do: "bg-amber-500 text-white border-amber-600"
  defp stage_active_class(:billed), do: "bg-sky-600 text-white border-sky-700"
  defp stage_active_class(:invoiced), do: "bg-sky-600 text-white border-sky-700"
  defp stage_active_class(:paid), do: "bg-emerald-600 text-white border-emerald-700"
  defp stage_active_class(:receipted), do: "bg-emerald-600 text-white border-emerald-700"
  defp stage_active_class(:all), do: "bg-gray-800 text-white border-gray-900"
  defp stage_active_class(_), do: "bg-gray-800 text-white border-gray-900"

  defp row_stage_badge(s) when s in [:needs_bill, :needs_invoice],
    do: "bg-amber-100 text-amber-900"

  defp row_stage_badge(s) when s in [:billed, :invoiced], do: "bg-sky-100 text-sky-900"
  defp row_stage_badge(s) when s in [:paid, :receipted], do: "bg-emerald-100 text-emerald-900"
  defp row_stage_badge(_), do: "bg-gray-100 text-gray-800"

  defp blocker_label(:no_contact), do: gettext("No contact match")
  defp blocker_label(:name_match), do: gettext("Contact by name only")
  defp blocker_label(_), do: nil

  defp format_dt(nil), do: "—"
  defp format_dt(%DateTime{} = dt), do: Calendar.strftime(dt, "%d/%m/%Y")

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
    %{
      uuid: row.uuid,
      internalId: row.internal_id,
      supplierName: row.supplier_name,
      supplierTIN: row.supplier_tin,
      issuerID: row.issuer_id || row.supplier_id,
      issuerTIN: row.supplier_tin,
      issuerIDType: row.issuer_id_type,
      buyerName: row.buyer_name,
      buyerTIN: row.buyer_tin,
      receiverTIN: row.buyer_tin,
      receiverName: row.buyer_name,
      receiverID: row.receiver_id,
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

  defp count_for(counts, key), do: Map.get(counts, key, 0)

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto w-11/12 max-w-6xl">
      <div class="flex flex-wrap items-center justify-between gap-2 mb-4">
        <p class="text-3xl font-medium">{@page_title}</p>
        <.link navigate={~p"/companies/#{@current_company.id}/e_invoices"} class="button blue">
          {gettext("Full E-Invoice list")}
        </.link>
      </div>

      <p class="text-sm text-gray-600 mb-3">
        {gettext("Received Valid documents only.")}
        <span class="font-medium">{gettext("Supplier bills")}</span>
        → {gettext("Pur Invoice / Payment")}.
        <span class="font-medium">{gettext("Self-billed (sales)")}</span>
        → {gettext("Invoice / Receipt")} ({gettext("customer self-billed you")}).
      </p>

      <div class="flex flex-wrap gap-2 mb-3">
        <button
          type="button"
          phx-click="filter_lane"
          phx-value-lane="purchase"
          class={chip_class(@lane, :purchase, "bg-indigo-600 text-white border-indigo-700")}
        >
          {gettext("Supplier bills")}
        </button>
        <button
          type="button"
          phx-click="filter_lane"
          phx-value-lane="sales"
          class={chip_class(@lane, :sales, "bg-violet-600 text-white border-violet-700")}
        >
          {gettext("Self-billed (sales)")}
        </button>
        <button
          type="button"
          phx-click="filter_lane"
          phx-value-lane="all"
          class={chip_class(@lane, :all, "bg-gray-800 text-white border-gray-900")}
        >
          {gettext("All")}
        </button>
      </div>

      <div class="flex flex-wrap gap-2 mb-4">
        <button
          :for={s <- Queue.stages_for(@lane)}
          type="button"
          phx-click="filter_stage"
          phx-value-stage={s}
          class={chip_class(@stage, s, stage_active_class(s))}
        >
          {Queue.stage_label(s)} ({count_for(@counts, s)})
        </button>
        <button
          type="button"
          phx-click="filter_stage"
          phx-value-stage="all"
          class={chip_class(@stage, :all, stage_active_class(:all))}
        >
          {gettext("All stages")} ({count_for(@counts, :all)})
        </button>
      </div>

      <form phx-submit="search" class="mb-4 flex flex-wrap gap-2 items-end">
        <div>
          <label class="block text-xs text-gray-500">{gettext("Search")}</label>
          <input
            type="search"
            name="terms"
            value={@terms}
            placeholder={gettext("Party, TIN, doc no…")}
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
              <th class="p-2">{gettext("Lane")}</th>
              <th class="p-2">{gettext("Stage")}</th>
              <th class="p-2">{gettext("Issued")}</th>
              <th class="p-2">{gettext("Party")}</th>
              <th class="p-2">{gettext("Internal ID")}</th>
              <th class="p-2 text-right">{gettext("Amount")}</th>
              <th class="p-2">{gettext("Local docs")}</th>
              <th class="p-2">{gettext("Blockers")}</th>
              <th class="p-2">{gettext("Actions")}</th>
            </tr>
          </thead>
          <tbody>
            <tr :if={@rows == []}>
              <td colspan="9" class="p-6 text-center text-gray-500">
                {gettext("No e-invoices in this lane / stage / window.")}
              </td>
            </tr>
            <tr
              :for={row <- @rows}
              class="border-t border-gray-100 hover:bg-gray-50 align-top"
            >
              <td class="p-2">
                <span class="text-xs font-medium text-gray-600">{Queue.flow_label(row.flow)}</span>
                <div class="text-[10px] text-gray-400">{row.type_name}</div>
              </td>
              <td class="p-2">
                <span class={"inline-block rounded px-2 py-0.5 text-xs font-medium #{row_stage_badge(row.stage)}"}>
                  {Queue.stage_label(row.stage)}
                </span>
              </td>
              <td class="p-2 whitespace-nowrap">{format_dt(row.issued_at)}</td>
              <td class="p-2">
                <div class="font-medium">{row.party_name || "—"}</div>
                <div class="text-xs text-gray-500">{row.party_tin}</div>
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
                <%= if row.flow == :purchase do %>
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
                  <div
                    :if={is_nil(row.pur_invoice_id) and is_nil(row.payment_id)}
                    class="text-gray-400"
                  >
                    —
                  </div>
                <% else %>
                  <div :if={row.invoice_no}>
                    INV:
                    <.link
                      class="text-blue-600 underline"
                      navigate={
                        ~p"/companies/#{@current_company.id}/Invoice/#{row.invoice_id}/edit"
                      }
                    >
                      {row.invoice_no}
                    </.link>
                  </div>
                  <div :if={row.receipt_no}>
                    RC:
                    <.link
                      class="text-blue-600 underline"
                      navigate={
                        ~p"/companies/#{@current_company.id}/Receipt/#{row.receipt_id}/edit"
                      }
                    >
                      {row.receipt_no}
                    </.link>
                  </div>
                  <div
                    :if={is_nil(row.invoice_id) and is_nil(row.receipt_id)}
                    class="text-gray-400"
                  >
                    —
                  </div>
                <% end %>
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
                  <%= if row.flow == :purchase do %>
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
                  <% else %>
                    <.link
                      :if={
                        row.stage == :needs_invoice and
                          FullCircle.Authorization.can?(
                            @current_user,
                            :create_invoice,
                            @current_company
                          )
                      }
                      target="_blank"
                      navigate={
                        ~p"/companies/#{@current_company.id}/Invoice/new?obj=#{einvoice_json(row)}"
                      }
                      class="blue button text-xs"
                    >
                      {gettext("New Invoice")}
                    </.link>
                    <.link
                      :if={
                        row.stage in [:needs_invoice, :invoiced] and
                          FullCircle.Authorization.can?(
                            @current_user,
                            :create_receipt,
                            @current_company
                          )
                      }
                      target="_blank"
                      navigate={
                        ~p"/companies/#{@current_company.id}/Receipt/new?obj=#{einvoice_json(row)}"
                      }
                      class="teal button text-xs"
                    >
                      {gettext("New Receipt")}
                    </.link>
                    <.link
                      :if={row.invoice_id}
                      navigate={
                        ~p"/companies/#{@current_company.id}/Invoice/#{row.invoice_id}/edit"
                      }
                      class="gray button text-xs"
                    >
                      {gettext("Open invoice")}
                    </.link>
                    <.link
                      :if={row.receipt_id}
                      navigate={
                        ~p"/companies/#{@current_company.id}/Receipt/#{row.receipt_id}/edit"
                      }
                      class="gray button text-xs"
                    >
                      {gettext("Open receipt")}
                    </.link>
                  <% end %>
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
