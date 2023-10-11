defmodule FullCircleWeb.TimeAttendLive.PunchTimeComponent do
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
    <div class="">
      <%= if !is_nil(@obj) do %>
        <%= for {ti, id, _st, fl} <- @obj do %>
          <.link
            :if={ti != ""}
            id={id}
            class="#text-blue-600 hover:font-bold"
            phx-value-id={id}
            phx-value-comp-id={@id}
            phx-click={:edit_timeattend}
          >
            <span class={["mr-1", if(fl == "IN", do: "text-green-800", else: "text-amber-800")]}>
              <%= ti %>
            </span>
          </.link>
        <% end %>
      <% end %>
    </div>
    """
  end
end
