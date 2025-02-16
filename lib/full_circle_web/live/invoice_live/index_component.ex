defmodule FullCircleWeb.InvoiceLive.IndexComponent do
  use FullCircleWeb, :live_component

  alias FullCircle.EInvMetas
  alias FullCircleWeb.Helpers

  @impl true
  def mount(socket) do
    {:ok, socket}
  end

  @impl true
  def update(assigns, socket) do
    {:ok, socket |> assign(assigns) |> get_e_invoices()}
  end

  defp get_e_invoices(socket) do
    socket
    |> assign(
      e_invs:
        EInvMetas.get_e_invs(
          socket.assigns.obj.e_inv_uuid || "",
          socket.assigns.obj.invoice_no,
          :buyerName,
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
        FullCircle.Billing.get_invoice_by_id(doc_id, socket.assigns.company, socket.assigns.user)
    ) |> get_e_invoices()
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
    cond do
      einv.status != "Valid" ->
        ~H"""
        <span class="font-semibold text-rose-400">Cannot match</span>
        """

      is_nil(fc.e_inv_uuid) or fc.e_inv_uuid == "" ->
        match(fc, einv, assigns)

      einv.uuid != fc.e_inv_uuid ->
        ~H"""
        <span class="font-semibold text-orange-400">Wrongly matched</span>
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
      class="text-xs bg-green-400 p-1 rounded-xl"
    >
      Match
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
      class="text-xs bg-orange-400 p-1 rounded-xl"
    >
      Remove Match
    </.link>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id={@id}
      class={"#{@ex_class} flex flex-row text-center tracking-tighter bg-gray-200 hover:bg-gray-400"}
    >
      <div class="w-[2%] border-b border-gray-400 mt-3 p-1">
        <input
          :if={@obj.checked and !@obj.old_data}
          id={"checkbox_invoice_#{@obj.id}"}
          type="checkbox"
          class="rounded border-gray-400 checked:bg-gray-400"
          phx-click="check_click"
          phx-value-object-id={@obj.id}
          checked
        />
        <input
          :if={!@obj.checked and !@obj.old_data}
          id={"checkbox_invoice_#{@obj.id}"}
          type="checkbox"
          class="rounded border-gray-400 checked:bg-gray-400"
          phx-click="check_click"
          phx-value-object-id={@obj.id}
        />
      </div>
      <div class="w-[6%] border-b border-gray-400 p-1">
        <div>{@obj.invoice_date |> FullCircleWeb.Helpers.format_date()}</div>
        <div>{@obj.due_date |> FullCircleWeb.Helpers.format_date()}</div>
      </div>

      <div class="w-[18%] border-b border-gray-400 overflow-clip p-1">
        <div>{@obj.contact_name}</div>
        <div class="text-sm">
          <%= if @obj.old_data do %>
            {@obj.invoice_no}
          <% else %>
            <.doc_link
              current_company={@company}
              doc_obj={%{doc_type: "Invoice", doc_id: @obj.id, doc_no: @obj.invoice_no}}
            />
          <% end %>
          {@obj.tax_id} <span class="text-green-600">{@obj.reg_no}</span>
        </div>
      </div>
      <div class="w-[18%] border-b text-center border-gray-400 overflow-clip p-1">
        <span class="font-light">{@obj.particulars}</span>
      </div>
      <div class="w-[7%] border-b border-gray-400 p-1">
        <div>{Number.Currency.number_to_currency(@obj.invoice_amount)}</div>
        <div class="text-orange-600">{Number.Currency.number_to_currency(@obj.balance)}</div>
      </div>
      <div class="w-[0.4%] bg-white"></div>

      <div class="w-[48.6%] p-1 border-b border-gray-400">
        <div :if={@e_invs == []} class="flex border-b border-amber-400 last:border-0">
          <.link
            target="_blank"
            href="https://myinvois.hasil.gov.my/newdocument"
            class="blue button"
          >
            {gettext("New E-Invoice")}
          </.link>
        </div>
        <%= for einv <- @e_invs do %>
          <div class="flex border-b border-amber-400 last:border-0">
            <div class="w-[22%]">
              <div>
                <div>
                  {einv.dateTimeReceived |> Helpers.format_datetime(@company)}
                </div>
                <div>
                  {einv.dateTimeIssued |> Helpers.format_datetime(@company)}
                </div>
                <div>
                  {if !is_nil(einv.rejectRequestDateTime) do
                    einv.rejectRequestDateTime |> Helpers.format_datetime(@company)
                  end}
                </div>
              </div>
            </div>
            <div class="w-[36%]">
              <a
                class="text-blue-600 hover:font-medium"
                target="_blank"
                href={~w(https://myinvois.hasil.gov.my/documents/#{einv.uuid})}
              >
                {einv.uuid}
              </a>
              <div class="text-sm">
                {"#{einv.internalId}"}
                <span class="font-bold text-green-600">Sent</span>
                <span class="text-purple-600">{einv.typeName} {einv.typeVersionName}</span>
              </div>
            </div>

            <div class="w-[42%]">
              <div class="overflow-hidden">{einv.buyerName}</div>
              <div class="text-sm">
                {einv.buyerTIN}
                <span class="font-bold">
                  {einv.documentCurrency} {einv.totalPayableAmount
                  |> Number.Delimit.number_to_delimited()}
                </span>
                <span :if={einv.status == "Valid"} class="text-green-600">{einv.status}</span>
                <span :if={einv.status == "Invalid"} class="text-rose-600">{einv.status}</span>
                <span :if={einv.status == "Canceled"} class="text-orange-600">{einv.status}</span>
                {matched_or_try_match(@obj, einv, assigns)}
              </div>
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end
end
