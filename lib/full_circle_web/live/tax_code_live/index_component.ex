defmodule FullCircleWeb.TaxCodeLive.IndexComponent do
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
      <span class="text-xl font-bold"><%= @obj.code %></span>
      <p>
        <%= @obj.tax_type %> &#11049; <%= @obj.rate
        |> Decimal.mult(100)
        |> Number.Percentage.number_to_percentage() %> &#11049; <%= @obj.account_name %>
      </p>
      <p><%= @obj.descriptions %></p>
      <span class="text-xs font-light"><%= to_fc_time_format(@obj.updated_at) %></span>
    </div>
    """
  end
end
