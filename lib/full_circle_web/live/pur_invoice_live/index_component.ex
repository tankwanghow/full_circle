defmodule FullCircleWeb.PurInvoiceLive.IndexComponent do
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
      class={"#{@ex_class} max-h-8 flex flex-row text-center tracking-tighter bg-gray-200 hover:bg-gray-400"}
    >
      <div class="w-[6%] border-b border-gray-400 py-1">
        <%= @obj.pur_invoice_date |> FullCircleWeb.Helpers.format_date() %>
      </div>
      <div class="w-[6%] border-b border-gray-400 py-1">
        <%= @obj.due_date |> FullCircleWeb.Helpers.format_date() %>
      </div>
      <div class="w-[8%] border-b border-gray-400 py-1">
        <%= if @obj.old_data do %>
          <%= @obj.pur_invoice_no %>
        <% else %>
          <.doc_link
            current_company={@company}
            doc_obj={%{doc_type: "PurInvoice", doc_id: @obj.id, doc_no: @obj.pur_invoice_no}}
          />
        <% end %>
      </div>
      <div class="w-[8%] border-b border-gray-400 py-1 italic font-light">
        <%= @obj.supplier_invoice_no %>
      </div>
      <div class="w-[22%] border-b border-gray-400 py-1 overflow-clip">
        <%= @obj.contact_name %>
      </div>
      <div class="w-[30%] border-b text-center border-gray-400 py-1 overflow-clip">
        <span class="font-light"><%= @obj.particulars %></span>
      </div>
      <div class="w-[10%] border-b border-gray-400 py-1">
        <%= Number.Currency.number_to_currency(@obj.pur_invoice_amount) %>
      </div>
      <div class="w-[10%] border-b border-gray-400 py-1">
        <%= Number.Currency.number_to_currency(@obj.balance) %>
      </div>
    </div>
    """
  end
end
