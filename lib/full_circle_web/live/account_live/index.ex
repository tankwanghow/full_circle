defmodule FullCircleWeb.AccountLive.Index do
  use FullCircleWeb, :live_view

  alias FullCircle.Accounting
  alias FullCircle.Accounting.Account

  @per_page 20

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-2xl mx-auto">
      <p class="w-full text-3xl text-center font-medium"><%= @page_title %></p>
      <.search_form search_val={@search.terms} />
      <div class="text-center mb-2">
        <.link phx-click={:new_account} class={"#{button_css()} text-xl"} id="new_account">
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
        <%= if @accounts_count > 0 do %>
          <%= for ac <- @accounts do %>
            <.live_component
              module={FullCircleWeb.AccountLive.AccountIndexComponent}
              id={"accounts-#{ac.id}"}
              account={ac}
              ex_class=""
            />
          <% end %>
        <% end %>
      </div>
      <.infinite_scroll_footer page={@page} count={@accounts_count} />
    </div>

    <.modal
      :if={@live_action in [:new, :edit]}
      id="any-modal"
      show
      on_cancel={JS.push("modal_cancel")}
    >
      <.live_component
        module={@module}
        id={@id}
        page_title={@page_title}
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
    {:noreply, socket |> assign(live_action: nil)}
  end

  @impl true
  def handle_event("new_account", _, socket) do
    {:noreply,
     socket
     |> assign(live_action: :new)
     |> assign(id: "new")
     |> assign(module: FullCircleWeb.AccountLive.FormComponent)
     |> assign(page_title: gettext("New Account"))
     |> assign(current_company: socket.assigns.current_company)
     |> assign(current_user: socket.assigns.current_user)
     |> assign(account: nil)
     |> assign(
       :form,
       to_form(Accounting.account_changeset(%Account{}, %{}, socket.assigns.current_company))
     )}
  end

  @impl true
  def handle_event("edit_account", %{"account-id" => id}, socket) do
    account = Accounting.get_account!(id)

    {:noreply,
     socket
     |> assign(live_action: :edit)
     |> assign(id: id)
     |> assign(module: FullCircleWeb.AccountLive.FormComponent)
     |> assign(page_title: gettext("Edit Account"))
     |> assign(current_company: socket.assigns.current_company)
     |> assign(current_user: socket.assigns.current_user)
     |> assign(account: account)
     |> assign(
       :form,
       to_form(Accounting.account_changeset(account, %{}, socket.assigns.current_company))
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
    send_update_after(
      self(),
      FullCircleWeb.AccountLive.AccountIndexComponent,
      [id: "accounts-#{ac.id}", account: ac, ex_class: "shake"],
      400
    )

    {:noreply,
     socket
     |> assign(update: "prepend")
     |> assign(live_action: nil)
     |> assign(accounts: [ac | socket.assigns.accounts])}
  end

  def handle_info({:updated, ac}, socket) do
    send_update_after(
      self(),
      FullCircleWeb.AccountLive.AccountIndexComponent,
      [id: "accounts-#{ac.id}", account: ac, ex_class: "shake"],
      400
    )

    {:noreply, socket |> assign(live_action: nil)}
  end

  def handle_info({:deleted, ac}, socket) do
    send_update_after(
      self(),
      FullCircleWeb.AccountLive.AccountIndexComponent,
      [id: "accounts-#{ac.id}", ex_class: "hidden"],
      400
    )

    {:noreply,
     socket
     |> put_flash(:info, "#{ac.name} #{gettext("Account Deleted")}")
     |> assign(live_action: nil)}
  end

  defp filter_accounts(socket, terms, page) do
    Accounting.filter_accounts(
      terms,
      socket.assigns.current_company,
      socket.assigns.current_user,
      page: page,
      per_page: @per_page
    )
  end
end
