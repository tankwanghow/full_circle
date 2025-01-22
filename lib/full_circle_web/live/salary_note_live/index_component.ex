defmodule FullCircleWeb.SalaryNoteLive.IndexComponent do
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
      class={"#{@ex_class} max-h-8 flex flex-row text-center tracking-tighter bg-gray-200 hover:bg-gray-400"}
    >
      <div class="w-[2%] border-b border-gray-400 py-1">
        <input
          :if={@obj.checked and !@obj.old_data}
          id={"checkbox_advance_#{@obj.id}"}
          type="checkbox"
          class="rounded border-gray-400 checked:bg-gray-400"
          phx-click="check_click"
          phx-value-object-id={@obj.id}
          checked
        />
        <input
          :if={!@obj.checked and !@obj.old_data}
          id={"checkbox_advance_#{@obj.id}"}
          type="checkbox"
          class="rounded border-gray-400 checked:bg-gray-400"
          phx-click="check_click"
          phx-value-object-id={@obj.id}
        />
      </div>
      <div class="w-[10%] border-b border-gray-400 py-1">
        {@obj.note_date |> FullCircleWeb.Helpers.format_date()}
      </div>
      <div class="w-[10%] border-b border-gray-400 py-1">
        <%= if @obj.old_data do %>
          {@obj.note_no}
        <% else %>
          <.doc_link
            current_company={@company}
            doc_obj={%{doc_type: "SalaryNote", doc_id: @obj.id, doc_no: @obj.note_no}}
          />
        <% end %>
      </div>
      <div class="w-[10%] border-b border-gray-400 py-1">
        {@obj.pay_slip_no}
      </div>
      <div class="w-[16%] border-b text-center border-gray-400 py-1 overflow-clip">
        <span class="font-light">{@obj.employee_name}</span>
      </div>
      <div class="w-[16%] border-b text-center border-gray-400 py-1 overflow-clip">
        <span class="font-light">{@obj.salary_type_name}</span>
      </div>
      <div class="w-[26%] border-b text-center border-gray-400 py-1 overflow-clip">
        <span class="font-light">{@obj.particulars}</span>
      </div>
      <div class="w-[10%] border-b border-gray-400 py-1">
        {Number.Currency.number_to_currency(@obj.amount)}
      </div>
    </div>
    """
  end
end
