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
      class={"#{@ex_class} text-center bg-gray-200 border-gray-500 hover:bg-gray-300 border-b"}
    >
      <div class="grid grid-cols-12">
        <div class="col-span-7 bg-gray-100 p-2">
          <.link
            navigate={~p"/companies/#{@current_company.id}/fixed_assets/#{@obj.id}/edit"}
            class="text-xl hover:font-bold text-blue-600"
          >
            <%= @obj.name %>
          </.link>
          <p>
            <span class="font-bold"><%= gettext("Fixed Asset Account:") %></span> <%= @obj.asset_ac_name %>
          </p>
          <p>
            <span class="font-bold"><%= gettext("Disposal Account:") %></span> <%= @obj.disp_fund_ac_name %>
          </p>
          <p>
            <span class="font-bold"><%= gettext("Depreciation Account:") %></span> <%= @obj.depre_ac_name %>
          </p>
          <span class="font-bold"><%= gettext("Cume Depreciation Account:") %></span>
          <%= @obj.cume_depre_ac_name %>
          <p><%= @obj.descriptions %></p>
        </div>
        <div class="col-span-5 p-2 bg-gray-200">
          <p>
            <%= gettext("Purchase Price:") %> - <%= Number.Currency.number_to_currency(@obj.pur_price) %>
          </p>
          <p>
            <.link
              :if={@obj.depre_method != "No Depreciation"}
              navigate={
                ~p"/companies/#{@current_company.id}/fixed_assets/#{@obj.id}/depreciations?terms=#{@terms}"
              }
              class="hover:font-bold text-blue-700"
            >
              <%= gettext("Depreciations") %> - <%= Number.Currency.number_to_currency(
                @obj.cume_depre
              ) %>
            </.link>
          </p>

          <p>
            <.link
              navigate={
                ~p"/companies/#{@current_company.id}/fixed_assets/#{@obj.id}/disposals?terms=#{@terms}"
              }
              class="hover:font-bold text-blue-700"
            >
              <%= gettext("Disposal") %> - <%= Number.Currency.number_to_currency(@obj.cume_disp) %>
            </.link>
          </p>

          <p>
            <%= gettext("Net Book Value") %> - <%= @obj.pur_price
            |> Decimal.sub(@obj.cume_disp || Decimal.new("0"))
            |> Decimal.sub(@obj.cume_depre || Decimal.new("0"))
            |> Number.Currency.number_to_currency() %>
          </p>
          <p>
            <%= gettext("Depreciation info") %> - <%= Number.Percentage.number_to_percentage(
              Decimal.mult(@obj.depre_rate, 100)
            ) %> &#9679; <%= @obj.depre_interval %><br />
          </p>
        </div>
      </div>
    </div>
    """
  end
end
