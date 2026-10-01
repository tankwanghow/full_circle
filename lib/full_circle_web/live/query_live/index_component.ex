defmodule FullCircleWeb.QueryLive.IndexComponent do
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
      <div class="w-[30%] shrink-0 min-w-0 truncate">
        <.link
          class="hover:font-bold text-purple-600"
          navigate={~p"/companies/#{@current_company.id}/queries/#{@obj.id}/edit"}
        >
          {@obj.qry_name}
        </.link>
      </div>
      <div
        class={["flex-1 min-w-0 truncate font-mono text-xs", muted_class()]}
        title={@obj.sql_string}
      >
        {@obj.sql_string}
      </div>
    </div>
    """
  end
end
