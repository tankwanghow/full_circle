defmodule FullCircleWeb.EInvListLive.IndexReceivedComponent do
  use FullCircleWeb, :live_component

  alias FullCircle.EInvMetas
  alias FullCircleWeb.Helpers

  @impl true
  def mount(socket) do
    {:ok, socket}
  end

  @impl true
  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  @impl true
  def handle_event("match", %{"einv" => einv, "fcdoc" => fc_doc}, socket) do
    case EInvMetas.match(
           Jason.decode!(einv),
           Jason.decode!(fc_doc),
           socket.assigns.company,
           socket.assigns.user
         ) do
      {:ok, _} ->
        new_fc_docs =
          EInvMetas.get_internal_document(
            socket.assigns.obj.typeName,
            "Received",
            socket.assigns.obj,
            socket.assigns.company
          )

        new_obj = Map.put(socket.assigns.obj, :fc_docs, new_fc_docs)

        {:noreply, assign(socket, obj: new_obj)}

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
    case EInvMetas.unmatch(Jason.decode!(fc_doc), socket.assigns.company, socket.assigns.user) do
      {:ok, _} ->
        new_fc_docs =
          EInvMetas.get_internal_document(
            socket.assigns.obj.typeName,
            "Received",
            socket.assigns.obj,
            socket.assigns.company
          )

        new_obj = Map.put(socket.assigns.obj, :fc_docs, new_fc_docs)

        {:noreply, assign(socket, obj: new_obj)}

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

  defp same_amount?(a, b) do
    case {a, b} do
      {%Decimal{} = x, %Decimal{} = y} -> Decimal.equal?(x, y)
      {x, y} when is_nil(x) or is_nil(y) -> x == y
      {x, y} -> to_string(x) == to_string(y)
    end
  end

  defp matched_or_try_match(doc, assigns) do
    cond do
      assigns.obj.status != "Valid" -> "Cannot match"
      is_nil(doc.e_inv_uuid) or doc.e_inv_uuid == "" -> match(doc, assigns)
      assigns.obj.uuid != doc.e_inv_uuid -> "wrong match"
      assigns.obj.uuid == doc.e_inv_uuid -> unmatch(doc, assigns)
    end
  end

  defp match(doc, assigns) do
    assigns = assigns |> assign(doc: doc)

    ~H"""
    <.link
      phx-target={@myself}
      phx-value-einv={Jason.encode!(@obj)}
      phx-value-fcdoc={Jason.encode!(@doc)}
      phx-click="match"
      class="text-xs bg-green-400 p-1 rounded-xl"
    >
      Match
    </.link>
    """
  end

  defp unmatch(doc, assigns) do
    assigns = assigns |> assign(doc: doc)

    ~H"""
    <.link
      phx-target={@myself}
      phx-value-fcdoc={Jason.encode!(@doc)}
      phx-click="unmatch"
      class="text-xs bg-orange-400 p-1 rounded-xl"
    >
      Remove Match
    </.link>
    """
  end

  defp new_fc(assigns) do
    ~H"""
    <div class="w-[99%] flex">
      <%= case @obj.typeName do %>
        <% type when type in ["Invoice", "Self-billed Invoice"] -> %>
          <.link
            target="_blank"
            navigate={~p"/companies/#{@company.id}/PurInvoice/new?obj=#{Jason.encode!(@obj)}"}
            class="blue button"
          >
            {gettext("New Pur Invoice")}
          </.link>
          <.link
            target="_blank"
            navigate={~p"/companies/#{@company.id}/Payment/new?obj=#{Jason.encode!(@obj)}"}
            class="green button"
          >
            {gettext("New Payment")}
          </.link>
        <% type when type in ["Credit Note", "Self-billed Debit Note"] -> %>
          <.link
            target="_blank"
            navigate={~p"/companies/#{@company.id}/DebitNote/new"}
            class="orange button"
          >
            {gettext("New Debit Note")}
          </.link>
        <% type when type in ["Debit Note", "Self-billed Credit Note"] -> %>
          <.link
            target="_blank"
            navigate={~p"/companies/#{@company.id}/CreditNote/new"}
            class="orange button"
          >
            {gettext("New Credit Note")}
          </.link>
        <% _ -> %>
      <% end %>
    </div>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class="flex flex-row bg-gray-200 hover:bg-gray-300">
      <div class="w-[49.8%] min-w-0 flex flex-row border-b border-amber-400 p-1">
        <div class="w-[20%] shrink-0 p-1 text-xs leading-snug">
          <div>
            {@obj.dateTimeReceived
            |> FullCircleWeb.Helpers.format_datetime(@company)}
          </div>
          <div>
            {@obj.dateTimeIssued
            |> FullCircleWeb.Helpers.format_datetime(@company)}
          </div>
          <div :if={!is_nil(@obj.rejectRequestDateTime)}>
            {@obj.rejectRequestDateTime
            |> FullCircleWeb.Helpers.format_datetime(@company)}
          </div>
        </div>
        <div class="w-[42%] min-w-0 px-1">
          <a
            class="block truncate text-blue-600 hover:font-medium text-xs"
            target="_blank"
            href={"#{@einv_portal}/documents/#{@obj.uuid}"}
            title={@obj.uuid}
          >
            {@obj.uuid}
          </a>
          <div class="text-xs truncate" title={@obj.internalId}>
            {@obj.internalId}
          </div>
          <div class="text-xs flex flex-wrap gap-x-1 gap-y-0.5 items-baseline">
            <span class="font-bold text-orange-600">Received</span>
            <span class="text-purple-600">{@obj.typeName} {@obj.typeVersionName}</span>
            <span :if={@obj.status == "Valid"} class="text-green-600">{@obj.status}</span>
            <span :if={@obj.status != "Valid"} class="text-rose-600">{@obj.status}</span>
          </div>
        </div>
        <div class="w-[38%] min-w-0 px-1">
          <div class="truncate font-medium" title={@obj.supplierName}>
            {@obj.supplierName}
          </div>
          <div class="text-xs text-gray-600 flex items-baseline gap-x-2 min-w-0">
            <span class="truncate shrink min-w-0" title={@obj.supplierTIN}>{@obj.supplierTIN}</span>
            <span class="font-bold text-sm text-gray-900 tabular-nums whitespace-nowrap ml-auto shrink-0">
              <span class="text-gray-500 text-xs font-normal">{@obj.documentCurrency}</span>
              {@obj.totalNetAmount |> Number.Delimit.number_to_delimited()}
              <span
                :if={!same_amount?(@obj.totalNetAmount, @obj.totalPayableAmount)}
                class="ml-2 font-semibold text-gray-600"
              >
                <span class="text-gray-400 text-[10px] font-normal">pay</span>
                {@obj.documentCurrency}
                {@obj.totalPayableAmount |> Number.Delimit.number_to_delimited()}
              </span>
            </span>
          </div>
        </div>
      </div>
      <div class="w-[0.4%] bg-white shrink-0"></div>
      <div class="w-[49.8%] min-w-0 p-1 border-b border-amber-400">
        {if Enum.count(@obj.fc_docs) == 0 and @obj.status == "Valid", do: new_fc(assigns)}
        <%= for doc <- @obj.fc_docs do %>
          <div class="flex min-w-0 border-b border-amber-400 last:border-0">
            <div class="w-[20%] shrink-0 text-xs">
              {doc.doc_date |> Helpers.format_date()}
            </div>
            <div class="w-[42%] min-w-0 px-1">
              <div class="truncate text-xs" title={doc.e_inv_uuid}>{doc.e_inv_uuid}</div>
              <div class="text-xs flex flex-wrap gap-x-1">
                <.doc_link current_company={@company} doc_obj={doc} />
                <span class="truncate">{doc.e_inv_internal_id}</span>
                <span class="text-purple-600">{doc.doc_type}</span>
              </div>
            </div>
            <div class="w-[38%] min-w-0 px-1 text-right">
              <div class="truncate text-left" title={doc.contact_name}>{doc.contact_name}</div>
              <div class="text-xs text-gray-600 truncate text-left">{doc.contact_tin}</div>
              <div class="text-sm font-bold tabular-nums whitespace-nowrap">
                {doc.amount |> Number.Delimit.number_to_delimited()}
              </div>
              <div class="text-xs">{matched_or_try_match(doc, assigns)}</div>
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end
end
