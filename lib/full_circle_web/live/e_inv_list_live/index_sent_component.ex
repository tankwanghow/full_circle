defmodule FullCircleWeb.EInvListLive.IndexSentComponent do
  use FullCircleWeb, :live_component

  alias FullCircle.EInvMetas
  alias FullCircleWeb.Helpers

  @impl true
  def mount(socket) do
    {:ok, socket}
  end

  @impl true
  def update(assigns, socket) do
    {:ok, socket |> assign(assigns) |> get_fc_docs()}
  end

  defp get_fc_docs(socket) do
    socket
    |> assign(
      fc_docs:
        EInvMetas.get_internal_document(
          socket.assigns.obj.typeName,
          "Sent",
          socket.assigns.obj,
          socket.assigns.company
        )
    )
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
        {:noreply, socket |> get_fc_docs()}

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
        {:noreply, socket |> get_fc_docs()}

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

  defp matched_or_try_match(doc, assigns) do
    cond do
      assigns.obj.status != "Valid" -> "Cannot match"
      is_nil(doc.e_inv_uuid) or doc.e_inv_uuid == "" -> match(doc, assigns)
      assigns.obj.uuid != doc.e_inv_uuid -> "wrong match"
      assigns.obj.uuid == doc.e_inv_uuid -> unmatch(doc, assigns)
    end
  end

  defp match(doc, assigns) do
    ~H"""
    <.link
      phx-target={@myself}
      phx-value-einv={Jason.encode!(@obj)}
      phx-value-fcdoc={Jason.encode!(doc)}
      phx-click="match"
      class="text-xs bg-green-400 p-1 rounded-xl"
    >
      Match
    </.link>
    """
  end

  defp unmatch(doc, assigns) do
    ~H"""
    <.link
      phx-target={@myself}
      phx-value-fcdoc={Jason.encode!(doc)}
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
      <.link target="_blank" navigate={~p"/companies/#{@company.id}/Invoice/new"} class="blue button">
        {gettext("New Invoice")}
      </.link>
      <.link target="_blank" navigate={~p"/companies/#{@company.id}/Receipt/new"} class="blue button">
        {gettext("New Receipt")}
      </.link>
      <.link
        target="_blank"
        navigate={~p"/companies/#{@company.id}/DebitNote/new"}
        class="blue button"
      >
        {gettext("New Debit Note")}
      </.link>
      <.link
        target="_blank"
        navigate={~p"/companies/#{@company.id}/CreditNote/new"}
        class="blue button"
      >
        {gettext("New Credit Note")}
      </.link>
    </div>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-row bg-gray-200 hover:bg-gray-300">
      <div class="w-[49.8%] text-nowrap flex flex-row p-1 border-b border-amber-400">
        <div class="w-[22%]">
          <div>
            <div>
              {@obj.dateTimeReceived |> Helpers.format_datetime(@company)}
            </div>
            <div>
              {@obj.dateTimeIssued |> Helpers.format_datetime(@company)}
            </div>
            <div>
              {if !is_nil(@obj.rejectRequestDateTime) do
                @obj.rejectRequestDateTime |> Helpers.format_datetime(@company)
              end}
            </div>
          </div>
        </div>
        <div class="w-[36%]">
          <a
            class="text-blue-600 hover:font-medium"
            target="_blank"
            href={~w(https://myinvois.hasil.gov.my/documents/#{@obj.uuid})}
          >
            {@obj.uuid}
          </a>
          <div class="text-xs">
            {"#{@obj.internalId}"}
            <span class="font-bold text-green-600">Sent</span>
            <span class="text-purple-600">{@obj.typeName} {@obj.typeVersionName}</span>
          </div>
        </div>

        <div class="w-[42%]">
          <div class="overflow-hidden">{@obj.buyerName}</div>
          <div class="text-sm">
            {@obj.buyerTIN}
            <span class="font-bold">
              {@obj.documentCurrency} {@obj.totalPayableAmount
              |> Number.Delimit.number_to_delimited()}
            </span>
            <span :if={@obj.status == "Valid"} class="text-green-600">{@obj.status}</span>
            <span :if={@obj.status == "Invalid"} class="text-rose-600">{@obj.status}</span>
            <span :if={@obj.status == "Canceled"} class="text-orange-600">{@obj.status}</span>
          </div>
        </div>
      </div>
      <div class="w-[0.4%] bg-white p-1"></div>
      <div class="w-[49.8%] p-1 border-b border-amber-400">
      {if Enum.count(@fc_docs) == 0 and @obj.status == "Valid", do: new_fc(assigns)}
        <%= for doc <- @fc_docs do %>
          <div class="flex border-b border-amber-400 last:border-0">
            <div class="w-[22%]">
              <div>
                <div>
                  {doc.doc_date |> Helpers.format_date()}
                </div>
              </div>
            </div>
            <div class="w-[36%]">
              {doc.e_inv_uuid}
              <div class="text-xs">
                <.doc_link current_company={@company} doc_obj={doc} />
                {doc.e_inv_internal_id}
                <span class="text-purple-600">{doc.doc_type}</span>
              </div>
            </div>

            <div class="w-[42%]">
              <div class="text-nowrap overflow-hidden">{doc.contact_name}</div>
              <div class="text-sm">
                {doc.contact_tin}
                <span class="font-bold">
                  {doc.amount
                  |> Number.Delimit.number_to_delimited()}
                </span>
                {matched_or_try_match(doc, assigns)}
              </div>
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end
end
