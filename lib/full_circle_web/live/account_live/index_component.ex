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
    <div
      id={@id}
      class={"#{@ex_class} cursor-pointer hover:bg-gray-400 accounts text-center mb-1 bg-gray-200 border-gray-500 border-2 rounded p-2"}
      phx-value-account-id={@account.id}
      phx-click={:edit_account}
    >
      <span class="text-xl font-bold"><%= @account.name %></span><br/>
      <p><%= @account.account_type %></p>
      <p><%= @account.descriptions %></p>
      <%= to_fc_time_format(@account.updated_at) %>
    </div>
    """
  end
end
