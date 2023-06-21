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
          <div class="my-4">
            <.link
              :if={@obj.depre_method != "No Depreciation"}
              phx-value-object-id={@obj.id}
              phx-value-object-name={@obj.name}
              navigate={~p"/companies/#{@company.id}/fixed_assets/#{@obj.id}/depreciations"}
              class="border bg-red-200 hover:bg-red-500 text-black rounded-full p-2 border-red-500 mx-1"
            >
              <%= gettext("Depreciations") %>
            </.link>
          </div>
          <div class="my-4">
            <.link
              phx-value-object-id={@obj.id}
              phx-value-object-name={@obj.name}
              navigate={~p"/companies/#{@company.id}/fixed_assets/#{@obj.id}/disposals"}
              class="border bg-amber-200 hover:bg-amber-500 text-black rounded-full p-2 border-amber-500"
            >
              <%= gettext("Disposal") %>
            </.link>
          </div>
          <div class="my-2">
            <.live_component
              module={FullCircleWeb.LogLive.Component}
              id={"log_#{@obj.id}"}
              show_log={false}
              entity="fixed_assets"
              entity_id={@obj.id}
            />
          </div>
          <div class="font-light"><%= to_fc_time_format(@obj.updated_at) %></div>
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
            <span class="font-bold"><%= gettext("Cume Depreciations:") %></span>
            <%= Number.Currency.number_to_currency(@obj.cume_depre) %><br />
            <span class="font-bold"><%= gettext("Cume Disposals:") %></span>
            <%= Number.Currency.number_to_currency(@obj.cume_disp) %><br />
            <span class="font-bold"><%= gettext("Net Book Value:") %></span>
            <%= @obj.pur_price
            |> Decimal.sub(@obj.cume_disp)
            |> Decimal.sub(@obj.cume_depre)
            |> Number.Currency.number_to_currency() %>
          </p>
          <p><%= @obj.descriptions %></p>
        </div>
      </div>
    </div>
    """
  end
end
