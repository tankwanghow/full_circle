defmodule FullCircleWeb.EInvListLive.IndexComponent do
  @moduledoc """
  One line per e-invoice on the E-Invoices listing: the LHDN document on the
  left, its Full Circle document(s) — or "+ New …" links — on the right.
  `direction` ("Received" | "Sent") picks the counterparty and the documents
  it maps to (see `EInvMetas.get_internal_document/4`).
  """
  use FullCircleWeb, :live_component
  import FullCircleWeb.ListComponents

  alias FullCircle.EInvMetas
  alias FullCircleWeb.Helpers

  @impl true
  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  @impl true
  def handle_event("match", %{"einv" => einv, "fcdoc" => fc_doc}, socket) do
    EInvMetas.match(
      Jason.decode!(einv),
      Jason.decode!(fc_doc),
      socket.assigns.company,
      socket.assigns.user
    )
    |> after_change(socket)
  end

  @impl true
  def handle_event("unmatch", %{"fcdoc" => fc_doc}, socket) do
    EInvMetas.unmatch(Jason.decode!(fc_doc), socket.assigns.company, socket.assigns.user)
    |> after_change(socket)
  end

  defp after_change({:ok, _}, socket) do
    obj = socket.assigns.obj

    fc_docs =
      EInvMetas.get_internal_document(
        obj.typeName,
        socket.assigns.direction,
        obj,
        socket.assigns.company
      )

    {:noreply, assign(socket, obj: Map.put(obj, :fc_docs, fc_docs))}
  end

  defp after_change({:error, failed_operation, changeset, _}, socket) do
    {:noreply,
     put_flash(
       socket,
       :error,
       "#{gettext("Failed")} #{failed_operation}. #{list_errors_to_string(changeset.errors)}"
     )}
  end

  defp after_change({:sql_error, msg}, socket) do
    {:noreply, put_flash(socket, :error, "#{gettext("Failed")} #{msg}")}
  end

  defp after_change(:not_authorise, socket) do
    {:noreply,
     put_flash(socket, :error, gettext("You are not authorised to perform this action"))}
  end

  # Must mirror get_internal_document/4: {label, doc type, prefill from e-invoice?}
  defp new_docs("Received", "Invoice"),
    do: [{gettext("Pur Invoice"), "PurInvoice", true}, {gettext("Payment"), "Payment", true}]

  defp new_docs("Received", "Self-billed Invoice"),
    do: [{gettext("Invoice"), "Invoice", true}, {gettext("Receipt"), "Receipt", true}]

  defp new_docs("Received", "Credit Note"), do: [{gettext("Debit Note"), "DebitNote", false}]

  defp new_docs("Received", "Self-billed Debit Note"),
    do: [{gettext("Credit Note"), "CreditNote", false}]

  defp new_docs("Received", "Debit Note"), do: [{gettext("Credit Note"), "CreditNote", false}]

  defp new_docs("Received", "Self-billed Credit Note"),
    do: [{gettext("Debit Note"), "DebitNote", false}]

  defp new_docs("Sent", "Invoice"),
    do: [{gettext("Invoice"), "Invoice", false}, {gettext("Receipt"), "Receipt", false}]

  defp new_docs("Sent", "Self-billed Invoice"),
    do: [{gettext("Pur Invoice"), "PurInvoice", true}, {gettext("Payment"), "Payment", true}]

  defp new_docs("Sent", "Credit Note"), do: [{gettext("Credit Note"), "CreditNote", false}]

  defp new_docs("Sent", "Self-billed Debit Note"),
    do: [{gettext("Debit Note"), "DebitNote", false}]

  defp new_docs("Sent", "Debit Note"), do: [{gettext("Debit Note"), "DebitNote", false}]

  defp new_docs("Sent", "Self-billed Credit Note"),
    do: [{gettext("Credit Note"), "CreditNote", false}]

  defp new_docs(_, _), do: []

  defp new_doc_path(company, obj, type, true),
    do: "/companies/#{company.id}/#{type}/new?" <> URI.encode_query(obj: Jason.encode!(obj))

  defp new_doc_path(company, _obj, type, false), do: "/companies/#{company.id}/#{type}/new"

  defp doc_state(obj, doc) do
    cond do
      obj.status != "Valid" -> :cannot
      doc.e_inv_uuid in [nil, ""] -> :match
      doc.e_inv_uuid != obj.uuid -> :wrong
      true -> :matched
    end
  end

  defp short_datetime(nil, _com), do: nil

  defp short_datetime(datetime, com) do
    datetime
    |> Timex.to_datetime(com.timezone)
    |> Timex.format!("%d-%m-%Y %H:%M", :strftime)
  end

  defp times_title(obj, com) do
    [
      {gettext("Received"), obj.dateTimeReceived},
      {gettext("Issued"), obj.dateTimeIssued},
      {gettext("Reject requested"), obj.rejectRequestDateTime}
    ]
    |> Enum.reject(fn {_, dt} -> is_nil(dt) end)
    |> Enum.map_join("\n", fn {label, dt} -> "#{label} #{Helpers.format_datetime(dt, com)}" end)
  end

  defp delimited(amount), do: Number.Delimit.number_to_delimited(amount)

  # Some vendors leave Total Net Amount at 0 and fill only Total Payable (or
  # the reverse, when prepaid), so show the larger and put both in the tooltip.
  defp amount_shown(%{totalNetAmount: net, totalPayableAmount: pay}) do
    net = net || Decimal.new(0)
    pay = pay || Decimal.new(0)
    if Decimal.gt?(net, pay), do: net, else: pay
  end

  defp amounts_title(obj) do
    if Decimal.equal?(obj.totalNetAmount || 0, obj.totalPayableAmount || 0) do
      nil
    else
      gettext("Net %{net}\nPayable %{pay}",
        net: "#{obj.documentCurrency} #{delimited(obj.totalNetAmount)}",
        pay: "#{obj.documentCurrency} #{delimited(obj.totalPayableAmount)}"
      )
    end
  end

  @impl true
  def render(assigns) do
    {name, tin} =
      if assigns.direction == "Sent",
        do: {assigns.obj.buyerName, assigns.obj.buyerTIN},
        else: {assigns.obj.supplierName, assigns.obj.supplierTIN}

    assigns =
      assigns
      |> assign(name: name, tin: tin)
      |> assign(valid?: assigns.obj.status == "Valid")
      |> assign(amounts_title: amounts_title(assigns.obj))

    ~H"""
    <div id={@id} class={row_class()}>
      <div class={line_class()}>
        <div
          class="w-36 shrink-0 tabular-nums whitespace-nowrap"
          title={times_title(@obj, @company)}
        >
          {short_datetime(@obj.dateTimeReceived, @company)}
        </div>
        <a
          class="w-40 shrink-0 truncate text-sky-700 dark:text-sky-400 hover:underline"
          target="_blank"
          href={"#{@einv_portal}/documents/#{@obj.uuid}"}
          title={"#{@obj.internalId}\nUUID #{@obj.uuid}"}
        >
          {@obj.internalId}
        </a>
        <div
          class={["w-32 shrink-0 truncate", muted_class()]}
          title={"#{@obj.typeName} #{@obj.typeVersionName}"}
        >
          {@obj.typeName}
        </div>
        <div class="flex-1 min-w-0 truncate" title={"#{@name}\nTIN #{@tin}"}>{@name}</div>
        <div
          class={[
            "w-32 shrink-0 text-right tabular-nums whitespace-nowrap",
            !@valid? && "line-through text-slate-400 dark:text-slate-500"
          ]}
          title={@amounts_title}
        >
          <span :if={@obj.documentCurrency != "MYR"} class={["text-xs", muted_class()]}>
            {@obj.documentCurrency}
          </span>
          {delimited(amount_shown(@obj))}<sup :if={@amounts_title} class="text-amber-600">*</sup>
        </div>
        <div class="w-20 shrink-0">
          <span :if={@valid?} class="text-xs text-emerald-700 dark:text-emerald-400">
            {@obj.status}
          </span>
          <.chip :if={!@valid?} kind={:bad}>{@obj.status}</.chip>
        </div>
        <div class="w-80 shrink-0 min-w-0 flex flex-col gap-1" data-col="fc">
          <%= cond do %>
            <% @obj.fc_docs == [] and @valid? -> %>
              <div class="flex flex-wrap gap-1">
                <.link
                  :for={{label, type, prefill} <- new_docs(@direction, @obj.typeName)}
                  target="_blank"
                  navigate={new_doc_path(@company, @obj, type, prefill)}
                  class="rounded border border-sky-400/70 px-2 py-0.5 text-xs text-sky-800 dark:text-sky-300 hover:bg-sky-100/60 dark:hover:bg-sky-950"
                >
                  + {label}
                </.link>
              </div>
            <% @obj.fc_docs == [] -> %>
              <span class="text-slate-400">—</span>
            <% true -> %>
              <.fc_doc
                :for={doc <- @obj.fc_docs}
                doc={doc}
                state={doc_state(@obj, doc)}
                obj={@obj}
                company={@company}
                myself={@myself}
              />
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  attr :doc, :map, required: true
  attr :state, :atom, required: true
  attr :obj, :map, required: true
  attr :company, :map, required: true
  attr :myself, :any, required: true

  defp fc_doc(assigns) do
    ~H"""
    <div
      class="flex items-center gap-2 min-w-0"
      title={
        "#{Helpers.format_date(@doc.doc_date)} · #{@doc.contact_name} · #{delimited(@doc.amount)}"
      }
    >
      <span
        :if={@state == :matched}
        class="shrink-0 text-emerald-700 dark:text-emerald-400"
        title={gettext("Matched")}
      >
        ✓
      </span>
      <.doc_link current_company={@company} doc_obj={@doc} klass="shrink-0" />
      <span class={["truncate min-w-0 text-xs", muted_class()]}>{@doc.doc_type}</span>
      <span class="ml-auto shrink-0">
        <%= case @state do %>
          <% :match -> %>
            <.link
              phx-target={@myself}
              phx-value-einv={Jason.encode!(@obj)}
              phx-value-fcdoc={Jason.encode!(@doc)}
              phx-click="match"
              class={[
                "rounded-full px-2 py-0.5 text-xs font-medium hover:underline",
                chip_class(:todo)
              ]}
            >
              {gettext("Match")}
            </.link>
          <% :matched -> %>
            <.link
              phx-target={@myself}
              phx-value-fcdoc={Jason.encode!(@doc)}
              phx-click="unmatch"
              class="text-xs text-slate-400 hover:text-rose-700 dark:hover:text-rose-300 hover:underline"
              title={gettext("Remove Match")}
            >
              × {gettext("remove")}
            </.link>
          <% :wrong -> %>
            <.chip kind={:bad}>{gettext("Wrongly matched")}</.chip>
          <% :cannot -> %>
            <span class="text-xs text-rose-700 dark:text-rose-300">{gettext("Cannot match")}</span>
        <% end %>
      </span>
    </div>
    """
  end
end
