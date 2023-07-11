defmodule FullCircleWeb.AccountLive.FormComponent do
  use FullCircleWeb, :live_component

  alias FullCircle.Accounting.Account
  alias FullCircle.StdInterface

  @impl true
  def mount(socket) do
    {:ok, socket}
  end

  @impl true
  def update(assigns, socket) do
    socket = socket |> assign(assigns)

    {:ok, socket}
  end

  @impl true
  def handle_event("validate", %{"account" => params}, socket) do
    changeset =
      StdInterface.changeset(
        Account,
        socket.assigns.form.data,
        params,
        socket.assigns.current_company
      )
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
    case FullCircle.Accounting.delete_account(
           socket.assigns.form.data,
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, ac} ->
        send(self(), {:deleted, ac})
        {:noreply, socket}

      {:error, failed_operation, changeset, _} ->
        send(self(), {:error, failed_operation, changeset})
        {:noreply, socket}

      :not_authorise ->
        send(self(), :not_authorise)
        {:noreply, socket}
    end
  end

  defp save_account(socket, :new, params) do
    case StdInterface.create(
           Account,
           "account",
           params,
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, ac} ->
        send(self(), {:created, ac})
        {:noreply, socket}

      {:error, _, changeset, _} ->
        assign(socket, form: to_form(changeset))

      :not_authorise ->
        send(self(), :not_authorise)
        {:noreply, socket}
    end
  end

  defp save_account(socket, :edit, params) do
    case StdInterface.update(
           Account,
           "account",
           socket.assigns.form.data,
           params,
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, ac} ->
        send(self(), {:updated, ac})
        {:noreply, socket}

      {:error, failed_operation, changeset, _} ->
        assign(socket, form: to_form(changeset))
        |> put_flash(
          :error,
          "#{gettext("Failed")} #{failed_operation}. #{list_errors_to_string(changeset.errors)}"
        )

      :not_authorise ->
        send(self(), :not_authorise)
        {:noreply, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <p class="w-full text-3xl text-center font-medium"><%= @title %></p>
      <.form
        for={@form}
        id="account-form"
        phx-target={@myself}
        autocomplete="off"
        phx-change="validate"
        phx-submit="save"
        class="w-full"
      >
        <.input field={@form[:name]} label={gettext("Account Name")} />

        <.input
          field={@form[:account_type]}
          label={gettext("Account Type")}
          type="select"
          options={FullCircle.Accounting.account_types()}
        />

        <.input field={@form[:descriptions]} label={gettext("Descriptions")} type="textarea" />

        <div class="flex justify-center gap-x-1 mt-1">
          <.button disabled={!@form.source.valid?}><%= gettext("Save") %></.button>
          <%= if @live_action == :edit and
                 FullCircle.Authorization.can?(@current_user, :delete_account, @current_company) do %>
            <.delete_confirm_modal
              id="delete-account"
              msg1={gettext("All Account Transactions, will be LOST!!!")}
              msg2={gettext("Cannot Be Recover!!!")}
              confirm={
                JS.remove_attribute("class", to: "#phx-feedback-for-tax_code_code")
                |> JS.push("delete", target: "#account-form")
                |> JS.hide(to: "#delete-object-modal")
              }
            />
          <% end %>
          <.link phx-click={JS.exec("phx-remove", to: "#object-crud-modal")} class="link_button">
            <%= gettext("Back") %>
          </.link>
        </div>
      </.form>
    </div>
    """
  end
end
