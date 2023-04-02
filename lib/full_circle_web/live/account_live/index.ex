defmodule FullCircleWeb.AccountLive.Index do
  use FullCircleWeb, :live_view

  alias FullCircle.Accounting.Account
  alias FullCircle.StdInterface
  alias FullCircleWeb.AccountLive.FormComponent
  alias FullCircleWeb.AccountLive.IndexComponent

  @per_page 10

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-2xl mx-auto">
      <p class="w-full text-3xl text-center font-medium"><%= @page_title %></p>
      <.search_form search_val={@search.terms} placeholder={gettext("Name, AccountType and Descriptions...")}/>
      <div class="text-center mb-2">
        <.link phx-click={:new_account} class={"#{button_css()} text-xl"} id="new_account">
          <%= gettext("Add New Account") %>
        </.link>
      </div>
      <div class="text-center mb-1">
        <div class="rounded bg-amber-200 border border-amber-500 font-bold p-2">
          <%= gettext("Account Information") %>
        </div>
      </div>
      <div id="accounts_list" phx-update={@update}>
        <%= for ac <- @accounts do %>
          <.live_component
            module={IndexComponent}
            id={"accounts-#{ac.id}"}
            account={ac}
            ex_class=""
          />
        <% end %>
      </div>
      <.infinite_scroll_footer page={@page} count={@accounts_count} per_page={@per_page} />
    </div>

    <.modal
      :if={@live_action in [:new, :edit]}
      id="any-modal"
      show
      on_cancel={JS.push("modal_cancel")}
    >
      <.live_component
        module={FormComponent}
        id={@id}
        title={@title}
        live_action={@live_action}
        form={@form}
        account={@account}
        current_company={@current_company}
        current_user={@current_user}
      />
    </.modal>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    accounts = filter_accounts(socket, "", 1)

    socket =
      socket
      |> assign(page_title: gettext("Accounts Listing"))
      |> assign(page: 1, per_page: @per_page)
      |> assign(search: %{terms: ""})
      |> assign(update: "append")
      |> assign(accounts_count: Enum.count(accounts))
      |> assign(accounts: accounts)

    {:ok, socket, temporary_assigns: [accounts: []]}
  end

  @impl true
  def handle_event("modal_cancel", _, socket) do
    IO.inspect(socket.assigns)
    {:noreply, socket |> assign(live_action: nil)}
  end

  @impl true
  def handle_event("new_account", _, socket) do
    {:noreply,
     socket
     |> assign(live_action: :new)
     |> assign(id: "new")
     |> assign(title: gettext("New Account"))
     |> assign(current_company: socket.assigns.current_company)
     |> assign(current_user: socket.assigns.current_user)
     |> assign(account: nil)
     |> assign(
       :form,
       to_form(StdInterface.changeset(Account, %Account{}, %{}, socket.assigns.current_company))
     )}
  end

  @impl true
  def handle_event("edit_account", %{"account-id" => id}, socket) do
    account = StdInterface.get!(Account, id)

    {:noreply,
     socket
     |> assign(live_action: :edit)
     |> assign(id: id)
     |> assign(title: gettext("Edit Account"))
     |> assign(current_company: socket.assigns.current_company)
     |> assign(current_user: socket.assigns.current_user)
     |> assign(account: account)
     |> assign(
       :form,
       to_form(StdInterface.changeset(Account, account, %{}, socket.assigns.current_company))
     )}
  end

  @impl true
  def handle_event("load-more", _, socket) do
    accounts = filter_accounts(socket, socket.assigns.search.terms, socket.assigns.page + 1)

    {:noreply,
     socket
     |> update(:page, &(&1 + 1))
     |> assign(update: "append")
     |> assign(accounts: accounts)
     |> assign(accounts_count: Enum.count(accounts))}
  end

  @impl true
  def handle_event("search", %{"search" => %{"terms" => terms}}, socket) do
    accounts = filter_accounts(socket, terms, 1)

    {:noreply,
     socket
     |> assign(page: 1, per_page: @per_page)
     |> assign(search: %{terms: terms})
     |> assign(update: "replace")
     |> assign(accounts_count: Enum.count(accounts))
     |> assign(accounts: accounts)}
  end

  @impl true
  def handle_info({:created, ac}, socket) do
    css_trans(IndexComponent, ac, :account, "accounts-#{ac.id}", "shake")

    {:noreply,
     socket
     |> assign(update: "prepend")
     |> assign(live_action: nil)
     |> assign(accounts: [ac | socket.assigns.accounts])}
  end

  def handle_info({:updated, ac}, socket) do
    css_trans(IndexComponent, ac, :account, "accounts-#{ac.id}", "shake")

    {:noreply, socket |> assign(live_action: nil)}
  end

  def handle_info({:deleted, ac}, socket) do
    css_trans(IndexComponent, ac, :account, "accounts-#{ac.id}", "slow-hide", "hidden")

    {:noreply,
     socket
     |> assign(live_action: nil)}
  end

  @impl true
  def handle_info({:error, failed_operation, failed_value}, socket) do
    {:noreply,
     socket
     |> assign(live_action: nil)
     |> put_flash(
       :error,
       "#{gettext("Failed")} #{failed_operation}. #{list_errors_to_string(failed_value.errors)}"
     )}
  end

  @impl true
  def handle_info(:not_authorise, socket) do
    {:noreply,
     socket
     |> assign(live_action: nil)
     |> put_flash(:error, gettext("You are not authorised to perform this action"))}
  end

  defp filter_accounts(socket, terms, page) do
    StdInterface.filter(
      Account,
      [:name, :account_type, :descriptions],
      terms,
      socket.assigns.current_company,
      socket.assigns.current_user,
      page: page,
      per_page: @per_page
    )
  end
end
