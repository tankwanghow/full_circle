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
    <div id={@id} class={"SalaryType_#{@klass}"}>
      <.inputs_for :let={sn} field={@types}>
        <div class={[
          "flex flex-row",
          if(sn[:delete].value == true, do: "hidden", else: "")
        ]}>
          <%= Phoenix.HTML.Form.hidden_input(sn, :id) %>
          <%= Phoenix.HTML.Form.hidden_input(sn, :cal_func) %>
          <%= Phoenix.HTML.Form.hidden_input(sn, :salary_type_type) %>
          <div class="w-[14%]">
            <.input field={sn[:note_date]} type="date" />
          </div>
          <div class="w-[11%]">
            <.input field={sn[:note_no]} readonly tabindex="-1" />
          </div>
          <div class="w-[21%]">
            <%= Phoenix.HTML.Form.hidden_input(sn, :salary_type_id) %>
            <.input
              field={sn[:salary_type_name]}
              phx-hook="tributeAutoComplete"
              phx-debounce="blur"
              url={"/api/companies/#{@current_company.id}/#{@current_user.id}/autocomplete?schema=salarytype&name="}
            />
          </div>
          <div class="w-[24%]">
            <.input field={sn[:descriptions]} />
          </div>
          <div class="w-[8%]">
            <.input field={sn[:quantity]} type="number" />
          </div>
          <div class="w-[9%]">
            <.input field={sn[:unit_price]} type="number" />
          </div>
          <div class="w-[11%]">
            <.input field={sn[:amount]} type="number" readonly tabindex="-1" />
          </div>
          <div class="w-[2%] mt-1 text-rose-500">
            <.link phx-click={:delete_note} phx-value-index={sn.index} tabindex="-1">
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
