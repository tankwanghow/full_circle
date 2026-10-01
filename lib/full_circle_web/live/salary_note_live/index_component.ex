defmodule FullCircleWeb.SalaryNoteLive.IndexComponent do
  use FullCircleWeb, :live_component

  import FullCircleWeb.ListComponents

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
      class={[row_class(@ex_class), line_class("gap-0")]}
    >
      <div class="w-6 shrink-0 text-center">
        <input
          :if={@obj.checked and !@obj.old_data}
          id={"checkbox_advance_#{@obj.id}"}
          type="checkbox"
          class="rounded border-gray-400"
          phx-click="check_click"
          phx-value-object-id={@obj.id}
          checked
        />
        <input
          :if={!@obj.checked and !@obj.old_data}
          id={"checkbox_advance_#{@obj.id}"}
          type="checkbox"
          class="rounded border-gray-400"
          phx-click="check_click"
          phx-value-object-id={@obj.id}
        />
      </div>
      <div class="w-[10%] shrink-0 min-w-0 truncate px-1">
        {@obj.note_date |> FullCircleWeb.Helpers.format_date()}
      </div>
      <div class="w-[10%] shrink-0 min-w-0 truncate px-1">
        <%= if @obj.old_data do %>
          {@obj.note_no}
        <% else %>
          <.doc_link
            current_company={@company}
            doc_obj={%{doc_type: "SalaryNote", doc_id: @obj.id, doc_no: @obj.note_no}}
          />
        <% end %>
      </div>
      <div class="w-[10%] shrink-0 min-w-0 truncate px-1">
        {@obj.pay_slip_no}
      </div>
      <div class="w-[16%] shrink-0 min-w-0 truncate px-1">
        <span class={muted_class()}>{@obj.employee_name}</span>
      </div>
      <div class="w-[16%] shrink-0 min-w-0 truncate px-1">
        <span class={muted_class()}>{@obj.salary_type_name}</span>
      </div>
      <div class="w-[26%] shrink-0 min-w-0 truncate px-1">
        <span class={muted_class()}>{@obj.particulars}</span>
      </div>
      <div class="w-[10%] shrink-0 min-w-0 truncate px-1 text-right tabular-nums">
        {Number.Currency.number_to_currency(@obj.amount)}
      </div>
    </div>
    """
  end
end
