defmodule FullCircleWeb.AccountLive.IndexComponent do
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
    <div id={@id} class={~s(#{@ex_class} text-center bg-gray-200 border-gray-500 border-b p-1)}>
      <%= if !FullCircle.Accounting.is_default_account?(@obj) do %>
        <.link
          class="hover:font-bold text-blue-600"
          navigate={~p"/companies/#{@current_company.id}/accounts/#{@obj.id}/edit"}
        >
          <%= @obj.name %>
        </.link>
      <% else %>
        <%= if @current_role == "admin" do %>
          <.link
            class="hover:font-bold text-purple-600"
            navigate={~p"/companies/#{@current_company.id}/accounts/#{@obj.id}/edit"}
          >
            <%= @obj.name %>
          </.link>
        <% else %>
          <span class="font-bold text-rose-600">
            <%= @obj.name %>
          </span>
        <% end %>
      <% end %>
      <span>(<%= @obj.account_type %>)</span>
      <p class="text-sm text-green-600"><%= @obj.descriptions %></p>
    </div>
    """
  end
end
