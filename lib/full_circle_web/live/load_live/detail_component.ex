defmodule FullCircleWeb.LoadLive.DetailComponent do
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
    <div id={@id} class={@klass}>
      <div class="font-medium flex flex-row text-center mt-2 tracking-tighter">
        <div class="w-[25%] font-bold"><%= gettext("Good") %></div>
        <div class="w-[25%] font-bold"><%= gettext("Description") %></div>
        <div class="w-[12%] font-bold"><%= gettext("Package") %></div>
        <div class="w-[10%] font-bold"><%= gettext("Package Qty") %></div>
        <div class="w-[10%] font-bold"><%= gettext("Quantity") %></div>
        <div class="w-[6%] font-bold"><%= gettext("Unit") %></div>
        <div class="w-[10%] font-bold"><%= gettext("Status") %></div>
        <div class="w-[2%]"></div>
      </div>

      <.inputs_for :let={dtl} field={@form[@detail_name]}>
        <div class={"flex flex-row #{if(dtl[:delete].value == true, do: "hidden", else: "")}"}>
          <.input field={dtl[:customer_name]} readonly={true} />
          <div class="w-[25%]">
            <.input
              field={dtl[:good_name]}
              phx-hook="tributeAutoComplete"
              phx-debounce="500"
              readonly={
                !is_nil(Phoenix.HTML.Form.input_value(dtl, :order_detail_id)) and
                  Phoenix.HTML.Form.input_value(dtl, :order_detail_id) != ""
              }
              url={"/api/companies/#{@current_company.id}/#{@current_user.id}/autocomplete?schema=good&name="}
            />
          </div>
          <%= Phoenix.HTML.Form.hidden_input(dtl, :order_detail_id) %>
          <%= Phoenix.HTML.Form.hidden_input(dtl, :good_id) %>
          <div class="w-[25%]"><.input field={dtl[:descriptions]} /></div>
          <div class="w-[12%]">
            <.input
              field={dtl[:package_name]}
              phx-hook="tributeAutoComplete"
              phx-debounce="500"
              url={"/api/companies/#{@current_company.id}/#{@current_user.id}/autocomplete?schema=packaging&good_id=#{dtl[:good_id].value}&name="}
            />
          </div>
          <%= Phoenix.HTML.Form.hidden_input(dtl, :unit_multiplier) %>
          <%= Phoenix.HTML.Form.hidden_input(dtl, :package_id) %>
          <div class="w-[10%]">
            <.input type="number" field={dtl[:load_pack_qty]} />
          </div>
          <div class="w-[10%]">
            <.input
              type="number"
              field={dtl[:load_qty]}
              step="0.0001"
              phx-debounce="500"
              readonly={Phoenix.HTML.Form.input_value(dtl, :unit_multiplier) |> Decimal.gt?(0)}
            />
          </div>
          <div class="w-[6%]">
            <.input field={dtl[:unit]} readonly tabindex="-1" />
          </div>
          <div class="w-[10%]">
            <.input field={dtl[:status]} type="select" options={["Processing", "Loaded", "Cancel"]} />
          </div>
          <div class="w-[2%] mt-1 text-rose-500">
            <.link phx-click={:delete_detail} phx-value-index={dtl.index} tabindex="-1">
              <.icon name="hero-trash-solid" class="h-5 w-5" />
            </.link>
            <%= Phoenix.HTML.Form.hidden_input(dtl, :delete) %>
          </div>
        </div>
      </.inputs_for>
      <div class="flex flex-row">
        <div class="mt-1 detail-good-col text-orange-500 text-left">
          <.link phx-click={:add_detail} class="hover:font-bold focus:font-bold">
            <.icon name="hero-plus-circle" class="w-5 h-5" /><%= gettext("Add Detail") %>
          </.link>
        </div>
      </div>
    </div>
    """
  end
end
