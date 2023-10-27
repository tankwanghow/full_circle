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
          "flex flex-row"
        ]}>
          <%= Phoenix.HTML.Form.hidden_input(sn, :_id) %>
          <div class="w-[14%]">
            <.input readonly tabindex="-1" field={sn[:slip_date]} type="date" />
          </div>
          <div class="w-[13%]">
            <.input readonly tabindex="-1" field={sn[:slip_no]} />
          </div>
          <div class="w-[21%]"><.input readonly tabindex="-1" name="ignore" value="Advance" /></div>
          <div class="w-[41%]">
            <.input readonly tabindex="-1" field={sn[:note]} />
          </div>
          <div class="w-[11%]">
            <.input field={sn[:amount]} type="number" readonly tabindex="-1" />
          </div>
        </div>
      </.inputs_for>
      <div :if={Decimal.gt?(@total_field.value, 0)} class="flex flex-row font-bold mb-1">
        <div class="w-[89%] text-right mr-3 mt-1"><%= @total_label %></div>
        <div class="w-[11%]">
          <.input readonly tabindex="-1" field={@total_field} type="number" />
        </div>
      </div>
    </div>
    """
  end
end
