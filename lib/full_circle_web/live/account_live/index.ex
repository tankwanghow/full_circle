defmodule FullCircleWeb.AccountLive.Index do
  use FullCircleWeb, :live_view

  alias FullCircle.Accounting
  # alias FullCircle.Accounting.Account

  @per_page 20

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-2xl mx-auto">
      <p class="w-full text-3xl text-center font-medium"><%= @page_title %></p>
      <.search_form search_val={@search.terms} />
      <div class="text-center mb-2">
        <.link
          navigate={~p"/companies/#{@current_company.id}/accounts/new"}
          class={"#{button_css()} text-xl"}
          id="new_account"
        >
          <%= gettext("Add New Account") %>
        </.link>
      </div>
      <div class="text-center grid grid-cols-12 gap-1 mb-1">
        <div class="col-span-4 rounded bg-amber-200 border border-amber-500 font-bold p-2">
          <%= gettext("Account Name") %>
        </div>
        <div class="col-span-3 rounded bg-amber-200 border border-amber-500 font-bold p-2">
          <%= gettext("Account Type") %>
        </div>
        <div class="col-span-5 rounded bg-amber-200 border border-amber-500 font-bold p-2">
          <%= gettext("Descriptions") %>
        </div>
      </div>
      <div id="accounts_list" phx-update={@update}>
        <%= if Enum.count(@accounts) > 0 do %>
          <%= for ac <- @accounts do %>
            <div id={"account_#{ac.id}"} class="accounts text-center grid grid-cols-12 gap-1 mb-1">
              <div class="col-span-4 rounded bg-gray-50 border-gray-400 border p-2">
                <.link
                  id={"edit_account_#{ac.id}"}
                  class="text-blue-600"
                  navigate={~p"/companies/#{@current_company.id}/accounts/#{ac.id}/edit"}
                >
                  <%= ac.name %>
                </.link>
              </div>
              <div class="col-span-3 rounded bg-gray-50 border-gray-400 border p-2">
                <%= ac.account_type %>
              </div>
              <div class="col-span-5 rounded bg-gray-50 border-gray-400 border p-2">
                <%= ac.descriptions %>
              </div>
            </div>
          <% end %>
        <% end %>
      </div>
      <.infinite_scroll_footer page={@page} count={@accounts_count} />
    </div>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(page_title: gettext("Accounts Listing"))
      |> assign(page: 1, per_page: @per_page)
      |> assign(search: %{terms: ""})
      |> assign(update: "append")
      |> filter_accounts("", 1)

    {:ok, socket, temporary_assigns: [accounts: []]}
  end

  @impl true
  def handle_event("load-more", _, socket) do
    {:noreply,
     socket
     |> update(:page, &(&1 + 1))
     |> assign(update: "append")
     |> filter_accounts(socket.assigns.search.terms, socket.assigns.page + 1)}
  end

  @impl true
  def handle_event("search", %{"search" => %{"terms" => terms}}, socket) do
    {:noreply,
     socket
     |> assign(page: 1, per_page: @per_page)
     |> assign(update: "replace")
     |> assign(search: %{terms: terms})
     |> filter_accounts(terms, 1)}
  end

  defp filter_accounts(socket, terms, page) do
    accounts =
      Accounting.filter_accounts(
        terms,
        socket.assigns.current_company,
        socket.assigns.current_user,
        page: page,
        per_page: @per_page
      )

    socket
    |> assign(accounts: accounts)
    |> assign(accounts_count: Enum.count(accounts))
  end
end
