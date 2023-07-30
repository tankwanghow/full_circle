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
      class={"#{@ex_class} max-h-8 flex flex-row text-center tracking-tighter bg-gray-200 hover:bg-gray-400"}
    >
      <div class="w-[2rem] border-b border-gray-400 py-1">
        <input
          :if={@obj.checked}
          id={"checkbox_invoice_#{@obj.id}"}
          name={"checkbox_invoice[#{@obj.id}]"}
          type="checkbox"
          phx-click="check_click"
          phx-value-object-id={@obj.id}
          checked
        />
        <input
          :if={!@obj.checked}
          id={"checkbox_invoice_#{@obj.id}"}
          name={"checkbox_invoice[#{@obj.id}]"}
          type="checkbox"
          phx-click="check_click"
          phx-value-object-id={@obj.id}
        />
      </div>
      <div class="w-[9rem] border-b border-gray-400 py-1">
        <%= @obj.invoice_date %>
      </div>
      <div class="w-[9rem] border-b border-gray-400 py-1">
        <%= @obj.due_date %>
      </div>
      <div :if={!@obj.old_data} class="text-blue-600 w-[10rem] border-b border-gray-400 py-1 hover:cursor-pointer">
        <.link patch={~p"/companies/#{@obj.company_id}/invoices/#{@obj.id}/edit"}><%= @obj.invoice_no %></.link>
      </div>
      <div :if={@obj.old_data}
        class="w-[10rem] border-b border-gray-400 py-1"
      >
        <%= @obj.invoice_no %>
      </div>
      <div class="w-[18.4rem] border-b border-gray-400 py-1 overflow-clip">
        <%= @obj.contact_name %>
      </div>
      <div class="w-[30rem] border-b text-center border-gray-400 py-1 overflow-clip">
        <span class="font-light"><%= @obj.particulars %></span>
      </div>
      <div class="w-[9rem] border-b border-gray-400 py-1">
        <%= Number.Currency.number_to_currency(@obj.invoice_amount) %>
      </div>
      <div class="w-[9rem] border-b border-gray-400 py-1">
        <%= Number.Currency.number_to_currency(@obj.balance) %>
      </div>
    </div>
    """
  end
end
