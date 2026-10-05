defmodule FullCircleWeb.EmployeeLive.IndexComponent do
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
    <div id={@id} class={[row_class(@ex_class), line_class()]}>
      <div class="w-6 shrink-0 text-center">
        <input
          :if={@obj.checked and @obj.status == "Active"}
          id={"checkbox_#{@obj.id}"}
          type="checkbox"
          phx-click="check_click"
          phx-value-object-id={@obj.id}
          class="rounded border-gray-400"
          checked
        />
        <input
          :if={!@obj.checked and @obj.status == "Active"}
          id={"checkbox_#{@obj.id}"}
          type="checkbox"
          class="rounded border-gray-400"
          phx-click="check_click"
          phx-value-object-id={@obj.id}
        />
      </div>
      <div class="flex-1 min-w-0 flex items-center gap-1 overflow-hidden">
        <.link
          class="min-w-0 truncate text-blue-600 hover:font-bold"
          tabindex="-1"
          navigate={~p"/companies/#{@current_company}/employees/#{@obj.id}/edit"}
        >
          {@obj.name}
        </.link>
        <.row_notes_badge count={@note_count} tasks={@task_count} id={@obj.id} />
      </div>
      <div class="w-[18%] shrink-0 truncate">{@obj.id_no}</div>
      <div class="w-[16%] shrink-0 truncate">{@obj.nationality}</div>
      <div class="w-24 shrink-0">
        <.chip kind={if @obj.status == "Active", do: :ok, else: :muted}>{@obj.status}</.chip>
      </div>
      <.link
        navigate={~p"/companies/#{@current_company}/employees/#{@obj.id}/copy"}
        class="w-14 shrink-0 text-xs text-center rounded-full border border-orange-400/70 px-2 py-0.5 text-orange-800 dark:text-orange-300 hover:bg-orange-100/60 dark:hover:bg-orange-950"
        tabindex="-1"
      >
        {gettext("Copy")}
      </.link>
    </div>
    """
  end
end
