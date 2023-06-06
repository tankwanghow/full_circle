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
    socket = socket |> assign(assigns)
    {:ok, socket}
  end

  @impl true
  def handle_event("show_log", _, socket) do
    {:noreply,
     socket
     |> assign(:show_log, true)
     |> assign(
       :logs,
       Sys.list_logs(
         socket.assigns.entity,
         socket.assigns.entity_id
       )
     )}
  end

  @impl true
  def handle_event("hide_log", _, socket) do
    {:noreply,
     socket
     |> assign(:show_log, false)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <span id={@id}>
      <.link
        phx-target={@myself}
        phx-click={:show_log}
        class="text-xs border rounded-full bg-pink-100 hover:bg-pink-400 px-2 py-1 border-pink-400"
      >
        <%= gettext("Logs") %>
      </.link>

      <.modal
        :if={@show_log}
        id={"object-log-modal-#{@id}"}
        show
        on_cancel={JS.push("hide_log", target: "##{@id}")}
      >
        <div class="max-w-full">
          <p class="w-full text-3xl text-center font-medium mb-3">
            <%= @page_title %>
          </p>
          <div id="logs_list">
            <%= for obj <- @logs do %>
              <div class="grid grid-cols-12 mb-2">
                <div class="col-span-4 text-center border rounded p-5 bg-blue-100">
                  <div class="font-medium"><%= obj.action %></div>
                  <div><%= obj.email %></div>
                  <div class="text-sm">
                    <%= FullCircleWeb.CoreComponents.to_fc_time_format(obj.inserted_at) %>
                  </div>
                </div>
                <div class="text-left col-span-8 border rounded p-2 bg-rose-100 text-xs font-mono">
                  <%= String.replace(obj.delta, "&^", "<p>")
                  |> String.replace("^&", "</p>")
                  |> String.replace("{", "<strong>")
                  |> String.replace("}", "</strong>")
                  |> String.replace("[", "<div class='pl-4'>")
                  |> String.replace("]", "</div>")
                  |> Phoenix.HTML.raw() %>
                </div>
              </div>
            <% end %>
          </div>
        </div>
      </.modal>
    </span>
    """
  end
end
