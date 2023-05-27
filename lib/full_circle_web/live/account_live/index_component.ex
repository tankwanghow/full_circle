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
      class={~s(#{@ex_class} text-center mb-1 bg-gray-200 border-gray-500 border-2 rounded p-2)}
    >
      <span
        class={
          ~s(text-xl font-bold px-2 py-1 rounded-full border
        #{if(FullCircle.Accounting.is_default_account?(@account),
          do: "cursor-not-allowed bg-rose-100 border-rose-400",
          else: "hover:bg-blue-400 cursor-pointer bg-blue-100 border-blue-500")}
            )
        }
        phx-value-account-id={@account.id}
        phx-click={
          if(FullCircle.Accounting.is_default_account?(@account), do: nil, else: :edit_account)
        }
      >
        <%= @account.name %>
      </span>
      <p class="text-sm mt-2"><%= @account.descriptions %></p>
      <span class="text-sm font-bold"><%= @account.account_type %></span>
      <span class="text-xs font-light"><%= to_fc_time_format(@account.updated_at) %></span>
      <.live_component
        module={FullCircleWeb.LogLive.Component}
        id={"log_#{@account.id}"}
        show_log={false}
        entity="accounts"
        entity_id={@account.id}
      />
    </div>
    """
  end
end
