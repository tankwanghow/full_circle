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
    <div>
    <%= if !is_nil(@obj) do %>
      <%= for {ti, id, st} <- @obj do %>
        <.link
          :if={ti != ""}
          class="text-blue-600 hover:font-bold"
          navigate={~p"/companies/#{@company}/TimeAttend/#{id}/edit"}
        >
          <span class="mr-3"><%= ti %><span :if={st == "Draft"} class="text-xs"> D</span></span>
        </.link>
      <% end %>
    <% end %>
    </div>
    """
  end
end
