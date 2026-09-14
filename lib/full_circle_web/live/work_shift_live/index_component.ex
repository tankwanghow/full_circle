defmodule FullCircleWeb.WorkShiftLive.IndexComponent do
  use FullCircleWeb, :live_component

  alias FullCircle.HR.WorkShift

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id={@id}
      class="flex flex-row text-center tracking-tighter border-b border-gray-300 dark:border-gray-600 py-1 hover:bg-gray-100 dark:hover:bg-gray-700"
    >
      <div class="w-[26%]">
        <.link
          navigate={~p"/companies/#{@current_company.id}/work_shifts/#{@obj.id}/edit"}
          class="text-blue-700 dark:text-blue-400"
        >
          {@obj.name}
        </.link>
        <span :if={@obj.is_default} class="ml-1 text-xs text-gray-500">
          {gettext("(default)")}
        </span>
      </div>
      <div class="w-[14%]">{Calendar.strftime(@obj.start_time, "%H:%M")}</div>
      <div class="w-[14%]">{Calendar.strftime(WorkShift.nominal_end(@obj), "%H:%M")}</div>
      <div class="w-[14%]">{@obj.normal_hour}</div>
      <div class="w-[14%]">{@obj.max_hour}</div>
      <div class="w-[18%]">{Calendar.strftime(WorkShift.cutover_time(@obj), "%H:%M")}</div>
    </div>
    """
  end
end
