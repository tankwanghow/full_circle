defmodule FullCircleWeb.QueryLive.IndexComponent do
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
      class={~s(#{@ex_class} hover:bg-gray-300 text-center bg-gray-200 border-gray-500 border-b p-1)}
    >
      <.link
        class="hover:font-bold text-purple-600 text-xl"
        navigate={~p"/companies/#{@current_company.id}/queries/#{@obj.id}/edit"}
      >
        {@obj.qry_name}
      </.link>
      <p class="text-xs text-green-600">{@obj.sql_string}</p>
    </div>
    """
  end
end
