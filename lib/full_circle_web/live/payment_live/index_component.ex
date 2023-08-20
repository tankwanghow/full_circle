defmodule FullCircleWeb.PaymentLive.IndexComponent do
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
      <div class="w-[2%] border-b border-gray-400 py-1">
        <input
          :if={@obj.checked and !@obj.old_data}
          id={"checkbox_#{@obj.id}"}
          name={"checkbox[#{@obj.id}]"}
          type="checkbox"
          phx-click="check_click"
          phx-value-object-id={@obj.id}
          checked
        />
        <input
          :if={!@obj.checked and !@obj.old_data}
          id={"checkbox_#{@obj.id}"}
          name={"checkbox[#{@obj.id}]"}
          type="checkbox"
          phx-click="check_click"
          phx-value-object-id={@obj.id}
        />
      </div>
      <div class="w-[10%] border-b border-gray-400 py-1">
        <%= @obj.payment_date %>
      </div>
      <div
        :if={!@obj.old_data}
        class="text-blue-600 w-[10%] border-b border-gray-400 py-1 hover:cursor-pointer"
      >
        <.link navigate={~p"/companies/#{@obj.company_id}/Payment/#{@obj.id}/edit"}>
          <%= @obj.payment_no %>
        </.link>
      </div>
      <div :if={@obj.old_data} class="w-[10%] border-b border-gray-400 py-1">
        <%= @obj.payment_no %>
      </div>
      <div class="w-[28%] border-b border-gray-400 py-1 overflow-clip">
        <%= @obj.contact_name %>
      </div>
      <div class="w-[40%] border-b text-center border-gray-400 py-1 overflow-clip">
        <span class="font-light"><%= @obj.particulars %></span>
      </div>
      <div class="w-[10%] border-b border-gray-400 py-1">
        <%= Number.Currency.number_to_currency(@obj.amount |> Decimal.abs()) %>
      </div>
    </div>
    """
  end
end
