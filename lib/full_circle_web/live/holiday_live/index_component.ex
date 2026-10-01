defmodule FullCircleWeb.HolidayLive.IndexComponent do
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
      <div class="flex-1 min-w-0 truncate">
        <.link
          class="hover:font-bold text-blue-600"
          navigate={~p"/companies/#{@current_company.id}/holidays/#{@obj.id}/edit"}
        >
          {@obj.name}
        </.link>
      </div>
      <div class="w-[20%] shrink-0 truncate">{@obj.short_name}</div>
      <div class="w-28 shrink-0 tabular-nums">
        {@obj.holidate |> FullCircleWeb.Helpers.format_date()}
      </div>
      <.link
        navigate={~p"/companies/#{@current_company}/holidays/#{@obj.id}/copy"}
        class="w-14 shrink-0 text-xs text-center rounded-full border border-orange-400/70 px-2 py-0.5 text-orange-800 dark:text-orange-300 hover:bg-orange-100/60 dark:hover:bg-orange-950"
        tabindex="-1"
      >
        {gettext("Copy")}
      </.link>
    </div>
    """
  end
end
