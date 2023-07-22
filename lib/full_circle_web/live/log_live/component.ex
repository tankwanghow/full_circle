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
    {:noreply,
     socket
     |> assign(:show_log, true)
     |> assign(
       :logs,
       make_logs_to_logs_diff(
         Sys.list_logs(
           socket.assigns.entity,
           socket.assigns.entity_id
         )
       )
     )}
  end

  @impl true
  def handle_event("hide_log", _, socket) do
    {:noreply,
     socket
     |> assign(:show_log, false)}
  end

  def make_logs_to_logs_diff(logs) do
    ([nil] ++ logs)
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [o1, o2] ->
      %{
        inserted_at: o2.inserted_at,
        email: o2.email,
        action: o2.action,
        delta:
          FullCircleWeb.Helpers.put_marker_in_diff_log_delta(
            if(is_nil(o1), do: "", else: o1.delta),
            o2.delta
          )
      }
    end)
    |> Enum.reverse()
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id}>
      <.link
        phx-target={@myself}
        phx-click={:show_log}
      >
        <.icon name="hero-table-cells-solid" class="w-5 h-5 text-pink-500" />
      </.link>

      <.modal
        :if={@show_log}
        id={"object-log-modal-#{@id}"}
        show
        on_cancel={JS.push("hide_log", target: "##{@id}")}
        max_w="max-w-6xl"
      >
        <div class="max-w-full text-black">
          <p class="w-full text-3xl text-center font-medium mb-3">
            <%= @page_title %>
          </p>
          <div id="logs_list">
            <%= for obj <- @logs do %>
              <div class="grid grid-cols-12 mb-2">
                <div class="col-span-4 text-center border rounded p-5 bg-blue-100">
                  <div class="font-medium">
                    <%= obj.action %>
                  </div>
                  <div><%= obj.email %></div>
                  <div class="text-sm">
                    <%= FullCircleWeb.CoreComponents.to_fc_time_format(obj.inserted_at) %>
                  </div>
                </div>
                <div class="text-left col-span-8 border rounded p-2 bg-rose-100 text-xs font-mono">
                  <%= obj.delta
                  |> FullCircleWeb.Helpers.make_log_delta_to_html()
                  |> Phoenix.HTML.raw() %>
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
