defmodule FullCircleWeb.LogLive.Component do
  use FullCircleWeb, :live_component

  alias FullCircle.Sys

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
      %{
        timestamp: curr.inserted_at,
        user_email: curr.email,
        log_action: curr.action,
        diff_content: generate_diff_content(if(prev == nil, do: "", else: prev.delta), curr.delta)
      }
    end)
    |> Enum.reverse()
  end

  defp generate_diff_content(prev_delta, curr_delta) do
    if formatted?(curr_delta) do
      cleaned_prev =
        if formatted?(prev_delta), do: clean_delta_string(prev_delta), else: prev_delta

      cleaned_curr = clean_delta_string(curr_delta)

      diff_result =
        String.myers_difference(cleaned_prev, cleaned_curr)
        |> Enum.map_join(fn
          {:del, text} -> "<del>#{text}</del>"
          {:ins, text} -> "<ins>#{text}</ins>"
          {_, text} -> text
        end)

      if prev_delta == "" do
        diff_result
      else
        diff_result
        |> String.split("\n")
        |> Enum.filter(&(String.contains?(&1, "<del>") or String.contains?(&1, "<ins>")))
        |> Enum.join("\n")
      end
    else
      # Just show the raw delta without any diff or formatting applied
      curr_delta
    end
  end

  defp formatted?(delta) do
    delta = delta || ""
    String.contains?(delta, "&^") && String.contains?(delta, "^&")
  end

  defp clean_delta_string(delta) do
    delta
    # Remove opening markers
    |> String.replace("&^", "")
    # Turn closing into newlines for readability
    |> String.replace("^&", "\n")
  end

  defp format_diff_to_html(diff) do
    diff
    # Indent nests
    |> String.replace("[", "<div style='padding-left: 1rem;'>")
    |> String.replace("]", "</div>")
    # Red strikethrough for deletions
    |> String.replace("<del>", "<span style='color: red; text-decoration: line-through;'>")
    |> String.replace("</del>", "</span>")
    # Green for insertions
    |> String.replace("<ins>", "<span style='color: green;'>")
    |> String.replace("</ins>", "</span>")
    # Line breaks
    |> String.replace("\n", "<br/>")
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
        max_width="max-w-5xl"
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
                  {log.diff_content |> format_diff_to_html() |> Phoenix.HTML.raw()}
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
