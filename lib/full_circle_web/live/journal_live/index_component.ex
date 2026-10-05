defmodule FullCircleWeb.JournalLive.IndexComponent do
  use FullCircleWeb, :live_component

  import FullCircleWeb.ListComponents

  @impl true
  def mount(socket) do
    {:ok, socket}
  end

  @impl true
  def update(assigns, socket) do
    {:ok, socket |> assign(assigns) |> assign_new(:note_count, fn -> 0 end)}
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
          id={"checkbox_#{@obj.id}"}
          type="checkbox"
          class="rounded border-gray-400"
          phx-click="check_click"
          phx-value-object-id={@obj.id}
          checked
        />
        <input
          :if={!@obj.checked and !@obj.old_data}
          id={"checkbox_#{@obj.id}"}
          type="checkbox"
          class="rounded border-gray-400"
          phx-click="check_click"
          phx-value-object-id={@obj.id}
        />
      </div>
      <div class="w-[9%] shrink-0 min-w-0 truncate px-1">
        {@obj.journal_date |> FullCircleWeb.Helpers.format_date()}
      </div>
      <div class="w-[9%] shrink-0 min-w-0 truncate px-1">
        <%= if @obj.old_data do %>
          {@obj.journal_no}
        <% else %>
          <.doc_link
            current_company={@company}
            doc_obj={%{doc_type: "Journal", doc_id: @obj.id, doc_no: @obj.journal_no}}
          />
          <.row_notes_badge count={@note_count} tasks={@task_count} id={@obj.id} />
        <% end %>
      </div>
      <div class="w-[40%] shrink-0 min-w-0 truncate px-1">
        {@obj.account_info}
      </div>
      <div class="w-[40%] shrink-0 min-w-0 truncate px-1">
        <span class={muted_class()}>{@obj.particulars}</span>
      </div>
    </div>
    """
  end
end
