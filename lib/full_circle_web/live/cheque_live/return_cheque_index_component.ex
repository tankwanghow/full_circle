defmodule FullCircleWeb.ChequeLive.ReturnChequeIndexComponent do
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
      <div class="w-[13%] border-b border-gray-400 py-1">
        <%= @obj.doc_date |> FullCircleWeb.Helpers.format_date() %>
      </div>

      <div
        :if={!@obj.old_data}
        class="text-blue-600 hover:font-bold w-[12%] border-b border-gray-400 py-1 hover:cursor-pointer"
      >
        <.link navigate={~p"/companies/#{@company.id}/ReturnCheque/#{@obj.return_id}/edit"}>
          <%= @obj.doc_no %>
        </.link>
      </div>

      <div :if={@obj.old_data} class="w-[12%] border-b border-gray-400 py-1">
        <%= @obj.doc_no %>
      </div>

      <div class="w-[30%] border-b border-gray-400 py-1 overflow-clip">
        <%= @obj.cheque_owner_name %>
      </div>

      <div class="w-[30%] border-b text-center border-gray-400 py-1 overflow-clip">
        <span class="font-light"><%= @obj.particulars %></span>
      </div>
      <div class="w-[15%] border-b border-gray-400 py-1">
        <%= Number.Currency.number_to_currency(@obj.amount) %>
      </div>
    </div>
    """
  end
end
