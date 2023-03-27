defmodule FullCircleWeb.AccountLive.Form do
  use FullCircleWeb, :live_view
  alias FullCircle.Accounting
  alias FullCircle.Accounting.Account

  @impl true
  def mount(params, _session, socket) do
    case socket.assigns.live_action do
      :new -> mount_new(socket)
      :edit -> mount_edit(params, socket)
    end
  end

  defp mount_new(socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("New Account"))
     |> assign(
       :form,
       to_form(Accounting.account_changeset(%Account{}, %{}, socket.assigns.current_company))
     )}
  end

  defp mount_edit(%{"id" => id}, socket) do
    account = Accounting.get_account!(id)
    changeset = Accounting.account_changeset(account, %{}, socket.assigns.current_company)

    {:ok,
     socket
     |> assign(:page_title, gettext("Editing Account"))
     |> assign(:form, to_form(changeset))
     |> assign(:account, account)}
  end

  @impl true
  def handle_event("validate", %{"account" => params}, socket) do
    account = if(socket.assigns[:account], do: socket.assigns.account, else: %Account{})

    changeset =
      account
      |> Accounting.account_changeset(params, socket.assigns.current_company)
      |> Map.put(:action, :insert)

    socket = assign(socket, form: to_form(changeset))

    {:noreply, socket}
  end

  @impl true
  def handle_event("save", %{"account" => params}, socket) do
    save_account(socket, socket.assigns.live_action, params)
  end

  @impl true
  def handle_event("delete", _params, socket) do
    case Accounting.delete_account(
           socket.assigns.account,
           socket.assigns.current_user,
           socket.assigns.current_company
         ) do
      {:ok, _com} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Account Deleted!"))
         |> push_navigate(to: ~p"/companies/#{socket.assigns.current_company.id}/accounts")}

      {:error, changeset, _} ->
        {:noreply,
         assign(socket, form: to_form(changeset))
         |> put_flash(:error, gettext("Failed to Delete Account"))}

      {:not_authorise, _, _} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("No Authorization"))
         |> push_navigate(to: ~p"/companies/#{socket.assigns.current_company.id}/accounts")}
    end
  end

  defp save_account(socket, :new, params) do
    case Accounting.create_account(
           params,
           socket.assigns.current_user,
           socket.assigns.current_company
         ) do
      {:ok, _} ->
        {:noreply,
         socket
         |> push_navigate(to: "/companies/#{socket.assigns.current_company.id}/accounts")}

      {:error, changeset, _} ->
        {:noreply,
         assign(socket, changeset: changeset)
         |> put_flash(:error, gettext("Failed to Create Account"))}

      {:not_authorise, changeset, _} ->
        {:noreply,
         assign(socket, changeset: changeset)
         |> put_flash(:error, gettext("No Authorization"))}
    end
  end

  defp save_account(socket, :edit, params) do
    case Accounting.update_account(
           socket.assigns.account,
           params,
           socket.assigns.current_user,
           socket.assigns.current_company
         ) do
      {:ok, _} ->
        {:noreply,
         socket
         |> push_navigate(to: "/companies/#{socket.assigns.current_company.id}/accounts")}

      {:error, changeset, _} ->
        {:noreply,
         assign(socket, changeset: changeset)
         |> put_flash(:error, gettext("Failed to Update Account"))}

      {:not_authorise, changeset, _} ->
        {:noreply,
         assign(socket, changeset: changeset)
         |> put_flash(:error, gettext("No Authorization"))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <p class="w-full text-3xl text-center font-medium"><%= @page_title %></p>
    <.form
      for={@form}
      id="account"
      autocomplete="off"
      phx-change="validate"
      phx-submit="save"
      class="max-w-md mx-auto"
    >
      <.input field={@form[:name]} label={gettext("Account Name")} />

      <.input
        field={@form[:account_type]}
        label={gettext("Account Type")}
        type="select"
        options={FullCircle.Accounting.account_types()}
      />

      <.input field={@form[:descriptions]} label={gettext("Descriptions")} type="textarea" />

      <div class="flex justify-center gap-x-1">
        <.button><%= gettext("Save") %></.button>
        <%= if @live_action == :edit and FullCircle.Authorization.can?(@current_user, :delete_account, @current_company) do %>
          <.delete_confirm_modal
            id="delete-account"
            msg1={gettext("All Account Transactions, will be LOST!!!")}
            msg2={gettext("Cannot Be Recover!!!")}
            confirm={JS.push("delete")}
            cancel={JS.navigate(~p"/companies/#{@current_company.id}/accounts/#{@account.id}/edit")}
          />
        <% end %>
        <.link navigate={"/companies/#{@current_company.id}/accounts"} class={button_css()}>
          <%= gettext("Back") %>
        </.link>
      </div>
    </.form>
    """
  end
end
