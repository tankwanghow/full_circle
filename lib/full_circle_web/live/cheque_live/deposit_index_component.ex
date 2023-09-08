defmodule FullCircleWeb.ChequeLive.DepositIndexComponent do
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
      <div class="w-[15%] border-b border-gray-400 py-1">
        <%= @obj.deposit_date %>
      </div>

      <div
        :if={!@obj.old_data}
        class="text-blue-600 w-[15%] border-b border-gray-400 py-1 hover:cursor-pointer"
      >
        <.link navigate={~p"/companies/#{@company.id}/Deposit/#{@obj.deposit_id}/edit"}>
          <%= @obj.deposit_no %>
        </.link>
      </div>

      <div :if={@obj.old_data} class="w-[15%] border-b border-gray-400 py-1">
        <%= @obj.deposit_no %>
      </div>


      <div class="w-[28%] border-b border-gray-400 py-1">
        <%= @obj.deposit_bank_name %>
      </div>
      <div class="w-[27%] border-b text-center border-gray-400 py-1 overflow-clip">
        <span class="font-light"><%= @obj.particulars %></span>
      </div>
      <div class="w-[15%] border-b border-gray-400 py-1">
        <%= Number.Currency.number_to_currency(@obj.amount) %>
      </div>
    </div>
    """
  end
end
