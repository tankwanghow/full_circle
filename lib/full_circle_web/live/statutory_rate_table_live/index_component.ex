defmodule FullCircleWeb.StatutoryRateTableLive.IndexComponent do
  use FullCircleWeb, :live_component

  @impl true
  def mount(socket) do
    {:ok, assign(socket, expanded: false)}
  end

  @impl true
  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  @impl true
  def handle_event("toggle", _params, socket) do
    {:noreply, assign(socket, expanded: !socket.assigns.expanded)}
  end

  defp format_value(v) when is_float(v) do
    if v == Float.round(v), do: v |> trunc() |> Integer.to_string(), else: to_string(v)
  end

  defp format_value(v), do: to_string(v)

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class={@ex_class}>
      <div
        phx-click="toggle"
        phx-target={@myself}
        class="text-center bg-gray-200 dark:bg-gray-700 border-gray-500 hover:bg-gray-300 dark:hover:bg-gray-600 border-b py-1 cursor-pointer"
        title={gettext("Click to show/hide values")}
      >
        <span class="font-bold text-blue-600 dark:text-blue-300">{@obj.code}</span>
        &#8226; {@obj.effective_from}
        &#8226; {Enum.join(@obj.columns, ", ")}
        &#8226; {gettext("%{count} rows", count: length(@obj.rows))}
        <span class="text-gray-500 dark:text-gray-400">{if @expanded, do: "▲", else: "▼"}</span>
      </div>
      <div :if={@expanded} class="border-b border-gray-500 py-2">
        <table class="mx-auto text-sm">
          <thead>
            <tr>
              <th
                :for={col <- @obj.columns}
                class="border border-gray-500 px-2 py-0.5 bg-amber-200 dark:bg-amber-800 font-mono"
              >
                {col}
              </th>
            </tr>
          </thead>
          <tbody>
            <tr :for={row <- @obj.rows}>
              <td
                :for={val <- row}
                class="border border-gray-400 px-2 py-0.5 text-right font-mono bg-gray-50 dark:bg-gray-800"
              >
                {format_value(val)}
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end
end
