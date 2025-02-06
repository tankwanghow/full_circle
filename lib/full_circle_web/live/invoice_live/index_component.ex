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
          socket.assigns.obj,
          socket.assigns.company
        ) || []
    )
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
          </div>
        </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end
end
