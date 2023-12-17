defmodule FullCircleWeb.ReportLive.StatementComponent do
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
    <div id={"objects-#{@id}"} class="flex flex-row text-center tracking-tighter">
      <div class="w-[10%] border rounded bg-green-200 border-green-400 px-2 py-1">
        <input
          :if={@obj.checked}
          id={"checkbox_#{@obj.id}"}
          name={"checkbox[#{@obj.id}]"}
          type="checkbox"
          phx-click="check_click"
          phx-value-object-id={@obj.id}
          class="rounded border-gray-400 checked:bg-gray-400"
          checked
        />
        <input
          :if={!@obj.checked}
          id={"checkbox_#{@obj.id}"}
          name={"checkbox[#{@obj.id}]"}
          type="checkbox"
          class="rounded border-gray-400 checked:bg-gray-400"
          phx-click="check_click"
          phx-value-object-id={@obj.id}
        />
      </div>
      <div class="w-[60%] border rounded bg-green-200 border-green-400 px-2 py-1">
        <%= @obj.name %>
      </div>
      <div class="w-[30%] border rounded bg-green-200 border-green-400 text-center px-2 py-1">
        <%= @obj.balance |> Number.Delimit.number_to_delimited() %>
      </div>
    </div>
    """
  end
end
