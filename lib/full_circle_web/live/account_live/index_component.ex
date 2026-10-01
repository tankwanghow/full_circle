defmodule FullCircleWeb.AccountLive.IndexComponent do
  use FullCircleWeb, :live_component

  import FullCircleWeb.ListComponents

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
    <div id={@id} class={[row_class(@ex_class), line_class()]}>
      <div class="w-[30%] shrink-0 min-w-0 truncate">
        <%= cond do %>
          <% !FullCircle.Accounting.is_default_account?(@obj) -> %>
            <.link
              class="hover:font-bold text-blue-600"
              navigate={~p"/companies/#{@current_company.id}/accounts/#{@obj.id}/edit"}
            >
              {@obj.name}
            </.link>
          <% @current_role == "admin" -> %>
            <.link
              class="hover:font-bold text-purple-600"
              navigate={~p"/companies/#{@current_company.id}/accounts/#{@obj.id}/edit"}
            >
              {@obj.name}
            </.link>
          <% true -> %>
            <span class="font-bold text-rose-600">{@obj.name}</span>
        <% end %>
      </div>
      <div class="w-[20%] shrink-0 truncate">{@obj.account_type}</div>
      <div class={["flex-1 min-w-0 truncate", muted_class()]} title={@obj.descriptions}>
        {@obj.descriptions}
      </div>
    </div>
    """
  end
end
