defmodule FullCircleWeb.ReceiptLive.IndexComponent do
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
          socket.assigns.obj.receipt_no,
          socket.assigns.obj.contact_name,
          socket.assigns.obj.funds_amount
          |> Decimal.add(socket.assigns.obj.cheques_amount)
          |> Decimal.abs(),
          socket.assigns.obj.receipt_date,
          socket.assigns.company,
          socket.assigns.user
        ) || []
    )
  end

  defp refresh_self(doc_id, socket) do
    socket
    |> assign(
      obj:
        FullCircle.ReceiveFund.get_receipt_by_id_index_component_field!(
          doc_id,
          socket.assigns.company,
          socket.assigns.user
        )
    )
    |> get_e_invoices()
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
          id={@fc.receipt_no}
          href="#"
          phx-hook="copyAndOpen"
          copy-text={@fc.receipt_no}
          goto-url="https://myinvois.hasil.gov.my/newdocument"
          class="border-blue-600 border hover:font-medium bg-blue-200 p-1 rounded-xl"
        >
          {gettext("New E-Invoice")}
        </a>
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
      class="bg-green-200 p-1 hover:font-medium rounded-xl border border-green-600"
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
      class="bg-orange-200 p-1 hover:font-medium rounded-xl border border-orange-600"
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
      class={"#{@ex_class}  flex flex-row text-center border-b border-gray-400 tracking-tighter bg-gray-200 hover:bg-gray-400"}
    >
      <div class="w-[2%] py-1 mt-3">
        <input
          :if={@obj.checked and !@obj.old_data and !@obj.old_data}
          id={"checkbox_#{@obj.id}"}
          type="checkbox"
          class="rounded border-gray-400 checked:bg-gray-400"
          phx-click="check_click"
          phx-value-object-id={@obj.id}
          checked
        />
        <input
          :if={!@obj.checked and !@obj.old_data and !@obj.old_data}
          id={"checkbox_#{@obj.id}"}
          type="checkbox"
          class="rounded border-gray-400 checked:bg-gray-400"
          phx-click="check_click"
          phx-value-object-id={@obj.id}
        />
      </div>
      <div class="w-[15%] py-1 text-left">
        <div>
          {@obj.receipt_date |> FullCircleWeb.Helpers.format_date()}
          <span :if={!@obj.old_data} class="text-sm">
            <.link
              navigate={~p"/companies/#{@obj.company_id}/Receipt/#{@obj.id}/edit"}
              class="text-blue-600 hover:font-bold"
            >
              {@obj.receipt_no}
            </.link>
            {if @obj.receipt_no != @obj.e_inv_internal_id, do: @obj.e_inv_internal_id}
          </span>
          <span :if={@obj.old_data} class="text-sm">{@obj.receipt_no}</span>
        </div>
        <div class="text-sm">
          {@obj.tax_id} <span class="text-green-600">{@obj.reg_no}</span>
        </div>
      </div>

      <div class="w-[25%] p-1">
        <div>{@obj.contact_name}</div>
        <div class="font-light">{@obj.particulars}</div>
      </div>

      <div class="w-[8%] py-1">
        <div>
          {@obj.funds_amount
          |> Decimal.add(@obj.cheques_amount)
          |> Decimal.abs()
          |> Number.Currency.number_to_currency()}
        </div>
        <div class="text-orange-500">
          {@obj.funds_amount
          |> Decimal.add(@obj.cheques_amount)
          |> Decimal.abs()
          |> Decimal.sub(@obj.details_amount)
          |> Decimal.sub(@obj.tax_amount)
          |> Decimal.add(@obj.matched_amount)
          |> Number.Currency.number_to_currency()}
        </div>
      </div>
      <div class="w-[0.4%] bg-white"></div>

      <div :if={@obj.got_details == 0} class="w-[48.6%] p-1">
        Not Matching Needed. Receive from Customer.
      </div>

      <div :if={@obj.got_details > 0} class="w-[48.6%] p-1">
        <div :if={@e_invs == []} class="flex border-b border-amber-400 last:border-0">
          <a
            id={@obj.receipt_no}
            href="#"
            phx-hook="copyAndOpen"
            copy-text={@obj.receipt_no}
            goto-url="https://myinvois.hasil.gov.my/newdocument"
            class="text-blue-600 hover:font-medium w-[20%] ml-5 mt-3"
          >
            {gettext("New E-Invoice")}
          </a>
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
                  {einv.documentCurrency}
                  <%= if Decimal.gt?(einv.totalNetAmount, einv.totalPayableAmount) do %>
                    {einv.totalNetAmount
                    |> Number.Delimit.number_to_delimited()}
                  <% else %>
                    {einv.totalPayableAmount
                    |> Number.Delimit.number_to_delimited()}
                  <% end %>
                </span>
                <span :if={einv.status == "Valid"} class="text-green-600">{einv.status}</span>
                <span :if={einv.status != "Valid"} class="text-rose-600">{einv.status}</span>
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
