defmodule FullCircleWeb.PaySlipLive.AdvanceComponent do
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
    <div id={@id} class="SalaryType_Advance">
      <.inputs_for :let={sn} field={@types}>
        <div class={[
          "flex flex-row",
          if(sn[:delete].value == true, do: "hidden", else: "")
        ]}>
          <%= Phoenix.HTML.Form.hidden_input(sn, :id) %>
          <div class="w-[14%]">
            <.input readonly tabindex="-1" field={sn[:slip_date]} type="date" />
          </div>
          <div class="w-[11%]">
            <.input readonly tabindex="-1" field={sn[:slip_no]} />
          </div>
          <div class="w-[21%]"><.input readonly tabindex="-1" name="ignore" value="Advance" /></div>
          <div class="w-[41%]">
            <.input readonly tabindex="-1" field={sn[:note]} />
          </div>
          <div class="w-[11%]">
            <.input field={sn[:amount]} type="number" readonly tabindex="-1" />
          </div>
          <div class="w-[2%] mt-1 text-rose-500">
            <.link phx-click={:delete_advance} phx-value-index={sn.index} tabindex="-1">
              <.icon name="hero-trash-solid" class="h-5 w-5" />
            </.link>
            <%= Phoenix.HTML.Form.hidden_input(sn, :delete) %>
          </div>
        </div>
      </.inputs_for>
      <div class="flex flex-row font-bold mb-1">
        <div class="w-[87%] text-right mr-3 mt-1"><%= @total_label %></div>
        <div class="w-[11%]">
          <.input readonly tabindex="-1" name="ignore" value={@total} type="number" />
        </div>
        <div class="w-[2%]"></div>
      </div>
    </div>
    """
  end
end
