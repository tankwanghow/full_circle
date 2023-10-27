defmodule FullCircleWeb.TimeAttendLive.AdvanceComponent do
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
      class={[
        "flex flex-row text-center bg-gray-200 hover:bg-gray-300 text-red-600",
        if(@obj.id == @shake_obj.id, do: "shake", else: "")
      ]}
    >
      <div class="w-[10%] border-b border-gray-400 py-1">
        <%= @obj.slip_date |> FullCircleWeb.Helpers.format_date() %>
      </div>
      <div class="w-[10%] border-b border-gray-400 py-1">
        <.link class="hover:font-bold" phx-value-id={@id} phx-click={:edit_advance}>
          <%= @obj.slip_no %>
        </.link>
      </div>
      <div class="w-[10%] border-b border-gray-400 py-1">
        <%= @obj.pay_slip_no %>
      </div>
      <div class="w-[20%] border-b text-center border-gray-400 py-1">
        <span class="font-light">Advance</span>
      </div>
      <div class="w-[26%] border-b text-center border-gray-400 py-1">
        <span class="font-light"><%= @obj.note %></span>
      </div>
      <div class="w-[8%] border-b border-gray-400 py-1"></div>
      <div class="w-[8%] border-b border-gray-400 py-1"></div>
      <div class="w-[8%] border-b border-gray-400 py-1">
        <%= Number.Currency.number_to_currency(@obj.amount) %>
      </div>
    </div>
    """
  end
end
