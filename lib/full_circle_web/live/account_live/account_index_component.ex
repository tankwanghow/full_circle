defmodule FullCircleWeb.AccountLive.AccountIndexComponent do
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
    <div id={@id} class={"#{@ex_class} accounts text-center grid grid-cols-12 gap-1 mb-1"}>
      <div class="col-span-4 rounded bg-gray-50 border-gray-400 border p-2">
        <.link
          id={"edit_account_#{@account.id}"}
          class="text-blue-600"
          phx-value-account-id={@account.id}
          phx-click={:edit_account}
        >
          <%= @account.name %>
        </.link>
      </div>
      <div class="col-span-3 rounded bg-gray-50 border-gray-400 border p-2">
        <%= @account.account_type %>
      </div>
      <div class="col-span-5 rounded bg-gray-50 border-gray-400 border p-2">
        <%= @account.descriptions %>
      </div>
    </div>
    """
  end
end
