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
      class={
        ~s(#{@ex_class} text-center mb-1 border-2 rounded p-2
        #{if(FullCircle.Accounting.is_default_account?(@account),
        do: "cursor-not-allowed bg-rose-100 border-rose-300",
        else: "hover:bg-gray-400 cursor-pointer bg-gray-200 border-gray-500")}
            )
      }
      phx-value-account-id={@account.id}
      phx-click={
        if(FullCircle.Accounting.is_default_account?(@account), do: nil, else: :edit_account)
      }
    >
      <span class="text-xl font-bold"><%= @account.name %></span>
      <p class="text-sm"><%= @account.descriptions %></p>
      <span class="text-xs font-bold"><%= @account.account_type %></span>
      <span class="text-xs font-light"><%= to_fc_time_format(@account.updated_at) %></span>
    </div>
    """
  end
end
