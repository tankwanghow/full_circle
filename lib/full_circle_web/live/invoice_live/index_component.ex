defmodule FullCircleWeb.InvoiceLive.IndexComponent do
  use FullCircleWeb, :live_component

  @impl true
  def mount(socket) do
    {:ok, socket}
  end

  @impl true
  def update(assigns, socket) do
    {:ok, socket |> assign(assigns)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id={@id}
      class={"#{@ex_class} flex flex-row text-center tracking-tighter bg-gray-200 hover:bg-gray-400"}
    >
      <div class="w-[2%] border-b border-gray-400 py-1">
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
      <div class="w-[11%] border-b border-gray-400 py-1">
        {@obj.invoice_date |> FullCircleWeb.Helpers.format_date()} / {@obj.due_date
        |> FullCircleWeb.Helpers.format_date()}
      </div>
      <div class="w-[8%] border-b border-gray-400 py-1">
        <%= if @obj.old_data do %>
          <%= @obj.invoice_no %>
        <% else %>
          <.doc_link
            current_company={@company}
            doc_obj={%{doc_type: "Invoice", doc_id: @obj.id, doc_no: @obj.invoice_no}}
          />
          <.e_invoice_link obj={@obj} />
        <% end %>
      </div>
      <div class="w-[20%] border-b border-gray-400 py-1 overflow-clip">
        {@obj.contact_name}
      </div>
      <div class="w-[39%] border-b text-center border-gray-400 py-1 overflow-clip">
        <span class="font-light">{@obj.particulars}</span>
      </div>
      <div class="w-[10%] border-b border-gray-400 py-1">
        {Number.Currency.number_to_currency(@obj.invoice_amount)}
      </div>
      <div class="w-[10%] border-b border-gray-400 py-1">
        {Number.Currency.number_to_currency(@obj.balance)}
      </div>
    </div>
    """
  end
end
