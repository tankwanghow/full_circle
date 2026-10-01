defmodule FullCircleWeb.InvoiceLive.IndexComponent do
  use FullCircleWeb, :live_component

  import FullCircleWeb.NoteComponents, only: [notes_count_badge: 1]

  alias FullCircle.EInvMetas
  alias FullCircleWeb.Helpers

  @impl true
  def mount(socket) do
    {:ok, socket}
  end

  @impl true
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:note_count, fn -> 0 end)
     |> assign_new(:einv_open, fn -> false end)
     |> get_e_invoices()}
  end

  defp get_e_invoices(socket) do
    socket
    |> assign(
      e_invs:
        EInvMetas.get_e_invs(
          socket.assigns.obj.e_inv_uuid || "",
          socket.assigns.obj.invoice_no,
          socket.assigns.obj.contact_name,
          socket.assigns.obj.invoice_amount,
          socket.assigns.obj.invoice_date,
          socket.assigns.company,
          socket.assigns.user
        ) || []
    )
  end

  defp refresh_self(doc_id, socket) do
    socket
    |> assign(
      obj:
        FullCircle.Billing.get_invoice_by_id_index_component_field!(
          doc_id,
          socket.assigns.company,
          socket.assigns.user
        )
    )
    |> get_e_invoices()
  end

  @impl true
  def handle_event("toggle_einv", _, socket) do
    {:noreply, update(socket, :einv_open, &(!&1))}
  end

  @impl true
  def handle_event("match", %{"einv" => einv, "fcdoc" => fc_doc}, socket) do
    einv = Jason.decode!(einv)
    fc_doc = Jason.decode!(fc_doc)

    case EInvMetas.match(
           einv,
           fc_doc,
           socket.assigns.company,
           socket.assigns.user
         ) do
      {:ok, _} ->
        {:noreply, refresh_self(fc_doc["doc_id"], socket)}

      {:error, failed_operation, changeset, _} ->
        {:noreply,
         socket
         |> assign(form: to_form(changeset))
         |> put_flash(
           :error,
           "#{gettext("Failed")} #{failed_operation}. #{list_errors_to_string(changeset.errors)}"
         )}

      {:sql_error, msg} ->
        {:noreply,
         socket
         |> put_flash(:error, "#{gettext("Failed")} #{msg}")}

      :not_authorise ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("You are not authorised to perform this action"))}
    end
  end

  @impl true
  def handle_event("unmatch", %{"fcdoc" => fc_doc}, socket) do
    fc_doc = Jason.decode!(fc_doc)

    case EInvMetas.unmatch(fc_doc, socket.assigns.company, socket.assigns.user) do
      {:ok, _} ->
        {:noreply, refresh_self(fc_doc["doc_id"], socket)}

      {:error, failed_operation, changeset, _} ->
        {:noreply,
         socket
         |> assign(form: to_form(changeset))
         |> put_flash(
           :error,
           "#{gettext("Failed")} #{failed_operation}. #{list_errors_to_string(changeset.errors)}"
         )}

      {:sql_error, msg} ->
        {:noreply,
         socket
         |> put_flash(:error, "#{gettext("Failed")} #{msg}")}

      :not_authorise ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("You are not authorised to perform this action"))}
    end
  end

  defp matched_or_try_match(fc, einv, assigns) do
    assigns = assigns |> assign(fc: fc) |> assign(einv: einv)

    cond do
      einv.status != "Valid" ->
        ~H"""
        <a
          id={"einv-new-#{@fc.id}-#{@einv.uuid}"}
          href="#"
          phx-hook="copyAndOpen"
          copy-text={@fc.invoice_no}
          goto-url={"#{@einv_portal}/newdocument"}
          class="text-sky-700 dark:text-sky-400 hover:underline"
        >
          {gettext("New E-Invoice")}
        </a>
        """

      is_nil(fc.e_inv_uuid) or fc.e_inv_uuid == "" ->
        match(fc, einv, assigns)

      einv.uuid != fc.e_inv_uuid ->
        ~H"""
        <span class="text-rose-700 dark:text-rose-300">{gettext("Wrongly matched")}</span>
        """

      einv.uuid == fc.e_inv_uuid ->
        unmatch(fc, assigns)
    end
  end

  defp match(fc, einv, assigns) do
    assigns = assigns |> assign(fc: fc) |> assign(einv: einv)

    ~H"""
    <.link
      phx-target={@myself}
      phx-value-einv={Jason.encode!(@einv)}
      phx-value-fcdoc={Jason.encode!(@fc)}
      phx-click="match"
      class={["rounded-full px-2 py-0.5 text-xs font-medium hover:underline", chip_class(:todo)]}
    >
      {gettext("Match")}
    </.link>
    """
  end

  defp unmatch(fc, assigns) do
    assigns = assigns |> assign(fc: fc)

    ~H"""
    <.link
      phx-target={@myself}
      phx-value-fcdoc={Jason.encode!(@fc)}
      phx-click="unmatch"
      class="rounded border border-rose-400/70 px-2 py-0.5 text-rose-800 dark:text-rose-300 hover:bg-rose-100/60 dark:hover:bg-rose-950"
    >
      {gettext("Remove Match")}
    </.link>
    """
  end

  # One summary state per invoice for the e-Invoice column; the expander
  # still lists every candidate with its own Match / Remove Match action.
  defp einv_state(obj, e_invs) do
    uuid = obj.e_inv_uuid
    matched? = uuid not in [nil, ""]
    matched = matched? && Enum.find(e_invs, &(&1.uuid == uuid))
    valid = Enum.filter(e_invs, &(&1.status == "Valid"))

    cond do
      matched && matched.status == "Valid" -> :valid
      matched -> {:problem, matched.status}
      matched? -> {:problem, gettext("Mismatch")}
      length(valid) == 1 -> {:match_one, hd(valid)}
      valid != [] -> {:match_many, length(valid)}
      true -> :not_sent
    end
  end

  defp overdue_days(obj) do
    if obj.due_date && Decimal.gt?(obj.balance, 0) do
      days = Date.diff(Date.utc_today(), obj.due_date)
      if days > 0, do: days
    end
  end

  defp money(amount), do: Number.Currency.number_to_currency(amount)

  defp chip_class(:ok),
    do: "bg-emerald-100/80 text-emerald-900 dark:bg-emerald-900/50 dark:text-emerald-300"

  defp chip_class(:todo),
    do: "bg-amber-100/80 text-amber-900 dark:bg-amber-900/50 dark:text-amber-300"

  defp chip_class(:bad),
    do: "bg-rose-100/80 text-rose-800 dark:bg-rose-900/50 dark:text-rose-300"

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:state, einv_state(assigns.obj, assigns.e_invs))
      |> assign(:overdue, overdue_days(assigns.obj))

    ~H"""
    <div
      id={@id}
      class={[
        @ex_class,
        "group border-b border-slate-200 dark:border-gray-700 text-sm",
        "hover:bg-sky-50/70 dark:hover:bg-gray-800/70"
      ]}
    >
      <div class="flex items-center gap-2 px-2 py-1.5">
        <div class="w-6 shrink-0 text-center">
          <%!-- Two inputs so a server-side toggle re-renders the checked state --%>
          <input
            :if={@obj.checked and !@obj.old_data}
            id={"checkbox_invoice_#{@obj.id}"}
            type="checkbox"
            class="rounded border-gray-400"
            phx-click="check_click"
            phx-value-object-id={@obj.id}
            checked
          />
          <input
            :if={!@obj.checked and !@obj.old_data}
            id={"checkbox_invoice_#{@obj.id}"}
            type="checkbox"
            class="rounded border-gray-400"
            phx-click="check_click"
            phx-value-object-id={@obj.id}
          />
        </div>

        <div
          class="w-24 shrink-0 tabular-nums"
          title={"#{gettext("Due")} #{FullCircleWeb.Helpers.format_date(@obj.due_date)}"}
        >
          {FullCircleWeb.Helpers.format_date(@obj.invoice_date)}
        </div>

        <div class="w-40 shrink-0 whitespace-nowrap">
          <%= if @obj.old_data do %>
            {@obj.invoice_no}
          <% else %>
            <.doc_link
              current_company={@company}
              doc_obj={%{doc_type: "Invoice", doc_id: @obj.id, doc_no: @obj.invoice_no}}
            />
            <%!-- Empty notes button only on hover; a count always shows --%>
            <span class={@note_count == 0 && "opacity-0 group-hover:opacity-100"}>
              <.notes_count_badge count={@note_count} id={@obj.id} />
            </span>
            <span
              :if={@obj.e_inv_internal_id && @obj.invoice_no != @obj.e_inv_internal_id}
              class="text-xs text-slate-500"
            >
              {@obj.e_inv_internal_id}
            </span>
          <% end %>
        </div>

        <div
          class="flex-1 min-w-0 truncate"
          title={Enum.join(Enum.reject([@obj.tax_id, @obj.reg_no], &(&1 in [nil, ""])), " · ")}
        >
          {@obj.contact_name}
        </div>

        <div
          class="w-[24%] shrink-0 truncate text-slate-500 dark:text-slate-400"
          title={@obj.particulars}
        >
          {@obj.particulars}
        </div>

        <div class="w-28 shrink-0 text-right tabular-nums">{money(@obj.invoice_amount)}</div>

        <div class="w-28 shrink-0 text-right tabular-nums">
          <%= if Decimal.eq?(@obj.balance, 0) do %>
            <span class="text-slate-400">—</span>
          <% else %>
            {money(@obj.balance)}
          <% end %>
        </div>

        <div
          data-col="overdue"
          class="w-16 shrink-0 text-right tabular-nums text-rose-700 dark:text-rose-400"
          title={
            @overdue &&
              gettext("due %{date}", date: FullCircleWeb.Helpers.format_date(@obj.due_date))
          }
        >
          {if @overdue, do: gettext("%{days}d", days: @overdue)}
        </div>

        <div class="w-36 shrink-0">{einv_chip(assigns)}</div>

        <button
          type="button"
          phx-click="toggle_einv"
          phx-target={@myself}
          class="w-6 shrink-0 text-slate-400 hover:text-slate-700 dark:hover:text-slate-200"
          title={gettext("e-Invoice details")}
        >
          {if @einv_open, do: "▾", else: "▸"}
        </button>
      </div>

      <div
        :if={@einv_open}
        class="ml-8 mr-2 mb-2 rounded border border-slate-200 dark:border-gray-700 text-xs"
      >
        <div :if={@e_invs == []} class="p-2 text-slate-500">
          {gettext("No e-invoice found for this invoice.")}
        </div>
        <div
          :for={einv <- @e_invs}
          class="flex flex-wrap items-center gap-x-5 gap-y-1 p-2 border-b border-slate-200 dark:border-gray-700 last:border-0"
        >
          <a
            class="text-sky-700 dark:text-sky-400 hover:underline"
            target="_blank"
            href={"#{@einv_portal}/documents/#{einv.uuid}"}
          >
            {einv.uuid}
          </a>
          <span>
            <span class="text-slate-500">{gettext("Received")}</span>
            {einv.dateTimeReceived |> Helpers.format_datetime(@company)}
          </span>
          <span>
            <span class="text-slate-500">{gettext("Issued")}</span>
            {einv.dateTimeIssued |> Helpers.format_datetime(@company)}
          </span>
          <span :if={einv.rejectRequestDateTime}>
            <span class="text-slate-500">{gettext("Reject requested")}</span>
            {einv.rejectRequestDateTime |> Helpers.format_datetime(@company)}
          </span>
          <span>{einv.internalId} · {einv.typeName} {einv.typeVersionName}</span>
          <span class="truncate max-w-64" title={einv.buyerTIN}>{einv.buyerName}</span>
          <span class="tabular-nums">
            {einv.documentCurrency}
            {Number.Delimit.number_to_delimited(
              if Decimal.gt?(einv.totalNetAmount, einv.totalPayableAmount),
                do: einv.totalNetAmount,
                else: einv.totalPayableAmount
            )}
          </span>
          <span class={[
            "rounded-full px-1.5",
            chip_class(if einv.status == "Valid", do: :ok, else: :bad)
          ]}>
            {einv.status}
          </span>
          <span class="ml-auto">{matched_or_try_match(@obj, einv, assigns)}</span>
        </div>
      </div>
    </div>
    """
  end

  defp einv_chip(assigns) do
    ~H"""
    <%= case @state do %>
      <% :valid -> %>
        <span class={["rounded-full px-2 py-0.5 text-xs font-medium", chip_class(:ok)]}>
          ✓ {gettext("Valid")}
        </span>
      <% {:problem, label} -> %>
        <span class={["rounded-full px-2 py-0.5 text-xs font-medium", chip_class(:bad)]}>
          ⚠ {label}
        </span>
      <% {:match_one, einv} -> %>
        {match(@obj, einv, assigns)}
      <% {:match_many, n} -> %>
        <button
          type="button"
          phx-click="toggle_einv"
          phx-target={@myself}
          class={["rounded-full px-2 py-0.5 text-xs font-medium", chip_class(:todo)]}
        >
          {gettext("%{n} to match", n: n)} ▸
        </button>
      <% :not_sent -> %>
        <a
          id={"einv-new-#{@obj.id}"}
          href="#"
          phx-hook="copyAndOpen"
          copy-text={@obj.invoice_no}
          goto-url={"#{@einv_portal}/newdocument"}
          class={["rounded-full px-2 py-0.5 text-xs font-medium hover:underline", chip_class(:todo)]}
          title={gettext("Copy the invoice no and open the MyInvois portal")}
        >
          ○ {gettext("Not sent")} →
        </a>
    <% end %>
    """
  end
end
