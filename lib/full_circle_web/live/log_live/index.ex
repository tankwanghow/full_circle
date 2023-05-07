defmodule FullCircleWeb.LogLive.Index do
  use FullCircleWeb, :live_view
  alias FullCircle.Sys

  @impl true
  def mount(%{"entity" => entity, "entity_id" => entity_id, "back" => back}, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Log Entries"))
     |> assign(:entity, entity)
     |> assign(:entity_id, entity_id)
     |> assign(:back, back)
     |> assign(
       :logs,
       Sys.list_logs(
         entity,
         entity_id,
         socket.assigns.current_company,
         socket.assigns.current_user
       )
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto">
      <p class="w-full text-3xl text-center font-medium mb-3">
        <%= @page_title %>
        <.link navigate={@back} class={"#{button_css()}"}><%= gettext("Back") %></.link>
      </p>
      <div id="objects_list">
        <%= for obj <- @logs do %>
          <div class="grid grid-cols-12 mb-2">
            <div class="col-span-4 text-center border rounded p-5 bg-blue-100">
              <div class="font-medium"><%= obj.action %></div>
              <div><%= obj.email %></div>
              <div class="text-sm">
                <%= FullCircleWeb.CoreComponents.to_fc_time_format(obj.inserted_at) %>
              </div>
            </div>
            <div class="col-span-8 border rounded p-2 bg-rose-100 text-xs font-mono">
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
    """
  end
end
