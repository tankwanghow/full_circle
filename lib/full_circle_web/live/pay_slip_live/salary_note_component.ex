defmodule FullCircleWeb.PaySlipLive.SalaryNoteComponent do
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
    <div id={@id} class={"SalaryType_#{@klass} mb-1"}>
      <.inputs_for :let={sn} field={@types}>
        <div class={[
          "flex flex-row"
        ]}>
          <.input type="hidden" field={sn[:_id]} />
          <.input type="hidden" field={sn[:cal_func]} />
          <.input type="hidden" field={sn[:salary_type_type]} />
          <.input type="hidden" field={sn[:recurring_id]} />
          <.input type="hidden" field={sn[:employee_id]} />
          <div class="w-[14%]">
            <.input field={sn[:note_date]} type="date" readonly tabindex="-1" />
          </div>
          <div class="w-[13%]">
            <.input field={sn[:note_no]} readonly tabindex="-1" />
          </div>
          <div class="w-[21%]">
            <.input field={sn[:salary_type_id]} type="hidden" />
            <.input readonly tabindex="-1" field={sn[:salary_type_name]} />
          </div>
          <div class="w-[24%]">
            <.input field={sn[:descriptions]} readonly tabindex="-1" />
          </div>
          <div class="w-[8%]">
            <.input field={sn[:quantity]} type="number" readonly tabindex="-1" />
          </div>
          <div class="w-[9%]">
            <.input field={sn[:unit_price]} type="number" readonly tabindex="-1" />
          </div>
          <div class="w-[11%]">
            <.input field={sn[:amount]} type="number" readonly tabindex="-1" />
          </div>
        </div>
      </.inputs_for>
      <div :if={!is_nil(@total_label)} class="flex flex-row font-bold">
        <div class="w-[89%] text-right mr-3 mt-1"><%= @total_label %></div>
        <div class="w-[11%]">
          <.input readonly tabindex="-1" field={@total_field} type="number" />
        </div>
      </div>
    </div>
    """
  end
end
