defmodule FullCircleWeb.TimeAttendLive.SalaryNoteComponent do
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
        "flex flex-row text-center bg-gray-200 hover:bg-gray-300",
        if(@obj.id == @shake_obj.id, do: "shake", else: ""),
        cond do
          @obj.salary_type_type == "Deduction" -> "text-red-600"
          @obj.salary_type_type == "Contribution" -> "text-amber-600"
          @obj.salary_type_type == "Addition" -> "text-green-600"
          true -> ""
        end
      ]}
    >
      <div class="w-[10%] border-b border-gray-400 py-1">
        <%= @obj.note_date |> FullCircleWeb.Helpers.format_date() %>
      </div>
      <div class="w-[10%] border-b border-gray-400 py-1">
        <.link class="hover:font-bold" phx-value-id={@id} phx-click={:edit_salarynote}>
          <%= @obj.note_no %>
        </.link>
      </div>
      <div class="w-[10%] border-b border-gray-400 py-1">
        <%= @obj.pay_slip_no %>
      </div>
      <div class="w-[20%] border-b text-center border-gray-400 py-1">
        <span class="font-light"><%= @obj.salary_type_name %></span>
      </div>
      <div class="w-[26%] border-b text-center border-gray-400 py-1">
        <span class="font-light"><%= @obj.descriptions %></span>
      </div>
      <div class="w-[8%] border-b border-gray-400 py-1">
        <%= Number.Delimit.number_to_delimited(@obj.quantity) %>
      </div>
      <div class="w-[8%] border-b border-gray-400 py-1">
        <%= Number.Currency.number_to_currency(@obj.unit_price) %>
      </div>
      <div class="w-[8%] border-b border-gray-400 py-1">
        <%= Number.Currency.number_to_currency(Decimal.mult(@obj.quantity, @obj.unit_price)) %>
      </div>
    </div>
    """
  end
end
