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
      class={"#{@ex_class} cursor-pointer hover:bg-gray-400 accounts text-center mb-1 bg-gray-200 border-gray-500 border-2 rounded p-2"}
      phx-value-object-id={@obj.id}
      phx-click={:edit_object}
    >
      <div class="grid grid-cols-12">
        <div class="col-span-4">
          <div class="text-xl font-medium"><%= @obj.invoice_no %></div>
          <div class="font-medium">
            <%= Number.Currency.number_to_currency(@obj.invoice_amount) %>
          </div>
          <div class="text-xs font-light"><%= to_fc_time_format(@obj.updated_at) %></div>

          <.link
            navigate={~p"/companies/#{@company.id}/invoices/#{@obj.id}/print?pre_print=false"}
            class="text-xs border rounded-full hover:bg-amber-200 px-1 py-1 border-black"
          >
            <%= gettext("Print") %>
          </.link>

          <.link
            navigate={~p"/companies/#{@company.id}/invoices/#{@obj.id}/print?pre_print=true"}
            class="ml-2 border border-black hover:bg-blue-200 text-xs text-white rounded-full px-1 py-1 bg-black"
          >
            <%= gettext("Pre Print") %>
          </.link>
        </div>
        <div class="col-span-8">
          <span class="font-medium text-sm"><%= gettext("Invoice Date") %>:</span>
          <span class="text-sm"><%= @obj.invoice_date %></span>
          <span class="font-medium text-sm"><%= gettext("Due Date") %>:</span>
          <span class="text-sm"><%= @obj.due_date %></span>
          <div class="text-xl font-medium"><%= @obj.contact_name %></div>
          <p class="text-sm font-light"><%= @obj.goods %></p>
          <p><%= @obj.tags %></p>
          <p class="text-sm font-light"><%= @obj.descriptions %></p>
        </div>
      </div>
    </div>
    """
  end
end
