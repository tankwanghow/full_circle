defmodule FullCircleWeb.FixedAssetLive.IndexComponent do
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
      <span class="text-xl font-bold"><%= @obj.name %></span>
      <p>
        <%= @obj.pur_date %> &#11049; <%= @obj.pur_price |> Number.Currency.number_to_currency() %> &#11049; <%= @obj.depre_method %> &#11049; <%= Number.Percentage.number_to_percentage(
          Decimal.mult(@obj.depre_rate, 100)
        ) %>
      </p>
      <p><%= @obj.asset_ac_name %> &#11049; <%= @obj.depre_ac_name %></p>
      <p><%= @obj.cume_depre_ac_name %></p>
      <p><%= @obj.descriptions %></p>
      <span class="text-xs font-light"><%= to_fc_time_format(@obj.updated_at) %></span>
    </div>
    """
  end
end
