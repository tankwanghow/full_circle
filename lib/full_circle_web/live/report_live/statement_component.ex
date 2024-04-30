defmodule FullCircleWeb.ReportLive.StatementComponent do
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
    <div id={"objects-#{@id}"} class="flex flex-row text-center tracking-tighter">
      <div class="w-[6%] border rounded bg-green-200 border-green-400 px-2 py-1">
        <input
          :if={@obj.checked}
          id={"checkbox_#{@obj.id}"}
          type="checkbox"
          phx-click="check_click"
          phx-value-object-id={@obj.id}
          class="rounded border-gray-400 checked:bg-gray-400"
          checked
        />
        <input
          :if={!@obj.checked}
          id={"checkbox_#{@obj.id}"}
          type="checkbox"
          class="rounded border-gray-400 checked:bg-gray-400"
          phx-click="check_click"
          phx-value-object-id={@obj.id}
        />
      </div>
      <div class="w-[47%] border rounded bg-green-200 border-green-400 px-2 py-1">
        <%= @obj.name %>
      </div>
      <div class="w-[13%] border rounded bg-blue-200 border-blue-400 text-center px-2 py-1">
        <%= @obj.balance |> Number.Delimit.number_to_delimited() %>
      </div>

      <div class="w-[8%] border rounded bg-rose-200 border-rose-400 text-center px-2 py-1">
        <%= @obj.chqs %>
      </div>
      <div class="w-[13%] border rounded bg-rose-200 border-rose-400 text-center px-2 py-1">
        <%= @obj.chqs_amt |> Number.Delimit.number_to_delimited() %>
      </div>
      <div class="w-[13%] border rounded bg-orange-200 border-orange-400 text-center px-2 py-1">
        <%= Decimal.add(@obj.balance, @obj.chqs_amt) |> Number.Delimit.number_to_delimited() %>
      </div>
    </div>
    """
  end
end
