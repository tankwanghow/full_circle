defmodule FullCircleWeb.RecurringLive.IndexComponent do
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
    <div id={@id} class={[row_class(@ex_class), line_class()]}>
      <div class="w-[14%] shrink-0 truncate">
        <.link
          class="text-blue-600 hover:font-bold"
          navigate={~p"/companies/#{@current_company}/recurrings/#{@obj.id}/edit"}
        >
          {@obj.recur_no}
        </.link>
      </div>
      <div class="w-28 shrink-0 tabular-nums">
        {@obj.recur_date |> FullCircleWeb.Helpers.format_date()}
      </div>
      <div class="flex-1 min-w-0 truncate">{@obj.employee_name}</div>
      <div class="w-[22%] shrink-0 truncate">{@obj.salary_type_name}</div>
      <div class="w-28 shrink-0 tabular-nums">
        {@obj.start_date |> FullCircleWeb.Helpers.format_date()}
      </div>
      <div class="w-24 shrink-0 truncate">{@obj.status}</div>
    </div>
    """
  end
end
