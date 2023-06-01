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
    <div id={@id} class={"#{@ex_class} text-center mb-1 bg-gray-200 border-gray-500 border-2 rounded"}>
      <div class="grid grid-cols-12">
        <div class="col-span-4 p-2 bg-gray-200">
          <.link
            phx-value-object-id={@obj.id}
            phx-click={:show_depreciation}
            class="border bg-red-200 hover:bg-red-500 text-sm text-black rounded-full px-2 py-1 border-red-500 mx-1"
          >
            <%= gettext("Depreciations") %>
          </.link>

          <.link
            navigate=""
            class="border bg-amber-200 hover:bg-amber-500 text-sm text-black rounded-full px-2 py-1 border-amber-500"
          >
            <%= gettext("Disposal") %>
          </.link>

          <span class="text-xs font-light"><%= to_fc_time_format(@obj.updated_at) %></span>
          <div>
            <.live_component
              module={FullCircleWeb.LogLive.Component}
              id={"log_#{@obj.id}"}
              show_log={false}
              entity="fixed_assets"
              entity_id={@obj.id}
            />
          </div>
        </div>
        <div
          class="col-span-8 bg-gray-100 p-2 hover:bg-gray-400 cursor-pointer"
          phx-value-object-id={@obj.id}
          phx-click={:edit_object}
        >
          <span class="text-xl font-bold">
            <%= @obj.name %>
          </span>
          <p>
            <span class="font-bold"><%= gettext("Fixed Asset Account:") %></span> <%= @obj.asset_ac_name %>
          </p>
          <p>
            <span class="font-bold"><%= gettext("Disposal Account:") %></span> <%= @obj.disp_fund_ac_name %>
          </p>
          <p>
            <span class="font-bold"><%= gettext("Purchase Info:") %></span>
            <%= @obj.pur_date %> &#9679; <%= Number.Currency.number_to_currency(@obj.pur_price) %>
          </p>
          <p>
            <span class="font-bold"><%= gettext("Depreciation info:") %></span>
            <%= @obj.depre_ac_name %> &#9679; <%= @obj.depre_start_date %> &#9679; <%= @obj.depre_method %> &#9679; <%= Number.Percentage.number_to_percentage(
              Decimal.mult(@obj.depre_rate, 100)
            ) %> &#9679; <%= @obj.depre_interval %>
          </p>
          <p><%= @obj.descriptions %></p>
        </div>
      </div>
    </div>
    """
  end
end
