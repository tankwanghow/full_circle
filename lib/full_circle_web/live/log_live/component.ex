defmodule FullCircleWeb.LogLive.Component do
  use FullCircleWeb, :live_component

  alias FullCircle.Sys
  alias FullCircleWeb.LogLive.DeltaDiff

  @impl true
  def mount(socket) do
    {
      :ok,
      socket
      |> assign(:page_title, gettext("Log Entries"))
    }
  end

  @impl true
  def update(assigns, socket) do
    {:ok, socket |> assign(assigns)}
  end

  @impl true
  def handle_event("show_log", _, socket) do
    logs = Sys.list_logs(socket.assigns.entity, socket.assigns.entity_id)
    diffed_logs = compute_log_diffs(logs)
    {:noreply, assign(socket, show_log: true, processed_logs: diffed_logs)}
  end

  @impl true
  def handle_event("hide_log", _, socket) do
    {:noreply,
     socket
     |> assign(:show_log, false)}
  end

  defp compute_log_diffs(logs) do
    ([nil] ++ logs)
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [prev, curr] ->
      prev_map = DeltaDiff.parse(if(prev == nil, do: "", else: prev.delta))
      curr_map = DeltaDiff.parse(curr.delta)

      %{
        timestamp: curr.inserted_at,
        user_email: curr.email,
        log_action: curr.action,
        diff_entries: DeltaDiff.diff(prev_map, curr_map)
      }
    end)
    |> Enum.reverse()
  end

  defp diff_tree(assigns) do
    assigns = assign_new(assigns, :depth, fn -> 0 end)

    ~H"""
    <div class={if @depth > 0, do: "ml-4 pl-2 border-l border-gray-300", else: ""}>
      <.diff_entry :for={entry <- @entries} entry={entry} depth={@depth} />
    </div>
    """
  end

  defp diff_entry(%{entry: %{status: :unchanged, key: key, value: value}} = assigns) do
    assigns = assign(assigns, :key, key) |> assign(:value, value)

    ~H"""
    <div class="py-0.5 text-gray-600">
      <span class="font-semibold">{@key}:</span> {@value}
    </div>
    """
  end

  defp diff_entry(
         %{entry: %{status: :changed, key: key, old_value: old_value, new_value: new_value}} =
           assigns
       ) do
    assigns =
      assign(assigns, :key, key) |> assign(:old_value, old_value) |> assign(:new_value, new_value)

    ~H"""
    <div class="py-0.5">
      <span class="font-semibold">{@key}:</span>
      <span class="text-red-600 line-through">{@old_value}</span>
      <span class="mx-1">&rarr;</span>
      <span class="text-green-600 font-bold">{@new_value}</span>
    </div>
    """
  end

  defp diff_entry(%{entry: %{status: :added, key: key, value: value}} = assigns) do
    assigns = assign(assigns, :key, key) |> assign(:value, value)

    ~H"""
    <div class="py-0.5 text-green-600">
      <span class="font-bold">+ {@key}:</span> {@value}
    </div>
    """
  end

  defp diff_entry(%{entry: %{status: :removed, key: key, value: value}} = assigns) do
    assigns = assign(assigns, :key, key) |> assign(:value, value)

    ~H"""
    <div class="py-0.5 text-red-600 line-through">
      <span class="font-semibold">- {@key}:</span> {@value}
    </div>
    """
  end

  defp diff_entry(%{entry: %{status: :nested, key: key, children: children}} = assigns) do
    assigns = assign(assigns, :key, key) |> assign(:children, children)

    ~H"""
    <div class="py-0.5">
      <span class="font-semibold text-gray-700">{@key}:</span>
      <.diff_tree entries={@children} depth={@depth + 1} />
    </div>
    """
  end

  defp diff_entry(%{entry: %{status: :added_nested, key: key, value: value}} = assigns) do
    flat = DeltaDiff.flatten_map(value)
    assigns = assign(assigns, :key, key) |> assign(:flat, flat)

    ~H"""
    <div class="py-0.5 text-green-600">
      <span class="font-bold">+ {@key}:</span>
      <div class="ml-4 pl-2 border-l border-green-300">
        <div :for={{k, v} <- @flat} class="py-0.5">
          <span class="font-semibold">{k}:</span> {v}
        </div>
      </div>
    </div>
    """
  end

  defp diff_entry(%{entry: %{status: :removed_nested, key: key, value: value}} = assigns) do
    flat = DeltaDiff.flatten_map(value)
    assigns = assign(assigns, :key, key) |> assign(:flat, flat)

    ~H"""
    <div class="py-0.5 text-red-600 line-through">
      <span class="font-semibold">- {@key}:</span>
      <div class="ml-4 pl-2 border-l border-red-300">
        <div :for={{k, v} <- @flat} class="py-0.5">
          <span class="font-semibold">{k}:</span> {v}
        </div>
      </div>
    </div>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id}>
      <.link
        phx-target={@myself}
        phx-click="show_log"
        class="bg-blue-500 text-white px-4 py-2 rounded block"
      >
        {gettext("Logs")}
      </.link>

      <.modal
        :if={@show_log}
        id={"log-viewer-#{@id}"}
        show
        on_cancel={JS.push("hide_log", target: @myself)}
        max_w="max-w-6xl"
      >
        <div class="text-gray-800">
          <h2 class="text-2xl font-bold text-center mb-4">
            {@page_title}
          </h2>
          <div class="space-y-4">
            <%= for log <- @processed_logs do %>
              <div class="grid grid-cols-1 md:grid-cols-3 gap-4 border p-4 rounded bg-gray-50">
                <div class="text-center bg-blue-50 p-3 rounded">
                  <p class="font-semibold">{log.log_action}</p>
                  <p>{log.user_email}</p>
                  <p class="text-xs text-gray-500">
                    {FullCircleWeb.CoreComponents.to_fc_time_format(log.timestamp, @current_company)}
                  </p>
                </div>
                <div class="md:col-span-2 bg-pink-50 p-3 rounded font-mono text-xs overflow-auto">
                  <.diff_tree entries={log.diff_entries} />
                </div>
              </div>
            <% end %>
          </div>
        </div>
      </.modal>
    </div>
    """
  end
end
