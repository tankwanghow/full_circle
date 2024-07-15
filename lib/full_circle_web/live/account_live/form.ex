defmodule FullCircleWeb.AccountLive.Form do
  use FullCircleWeb, :live_view

  alias FullCircle.Accounting.Account
  alias FullCircle.StdInterface

  @impl true
  def mount(params, _session, socket) do
    id = params["account_id"]

    socket =
      case socket.assigns.live_action do
        :new -> mount_new(socket)
        :edit -> mount_edit(socket, id)
      end

    {:ok, socket}
  end

  defp mount_new(socket) do
    socket
    |> assign(live_action: :new)
    |> assign(id: "new")
    |> assign(page_title: gettext("New Account"))
    |> assign(
      :form,
      to_form(StdInterface.changeset(Account, %Account{}, %{}, socket.assigns.current_company))
    )
  end

  defp mount_edit(socket, id) do
    account = StdInterface.get!(Account, id)

    socket
    |> assign(live_action: :edit)
    |> assign(id: id)
    |> assign(page_title: gettext("Edit Account"))
    |> assign(
      :form,
      to_form(StdInterface.changeset(Account, account, %{}, socket.assigns.current_company))
    )
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
    save(socket, socket.assigns.live_action, params)
  end

  @impl true
  def handle_event("delete", _params, socket) do
    case FullCircle.Accounting.delete_account(
           socket.assigns.form.data,
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, _ac} ->
        {:noreply,
         socket
         |> push_navigate(to: "/companies/#{socket.assigns.current_company.id}/accounts")
         |> put_flash(:info, "#{gettext("Account deleted successfully.")}")}

      {:error, failed_operation, changeset, _} ->
        {:noreply,
         socket
         |> assign(form: to_form(changeset))
         |> put_flash(
           :error,
           "#{gettext("Failed")} #{failed_operation}. #{list_errors_to_string(changeset.errors)}"
         )}

      :not_authorise ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("You are not authorised to perform this action"))}
    end
  end

  defp save(socket, :new, params) do
    case StdInterface.create(
           Account,
           "account",
           params,
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, ac} ->
        {:noreply,
         socket
         |> push_navigate(
           to: ~p"/companies/#{socket.assigns.current_company.id}/accounts/#{ac.id}/edit"
         )
         |> put_flash(:info, "#{gettext("Account created successfully.")}")}

      {:error, failed_operation, changeset, _} ->
        {:noreply,
         socket
         |> assign(form: to_form(changeset))
         |> put_flash(
           :error,
           "#{gettext("Failed")} #{failed_operation}. #{list_errors_to_string(changeset.errors)}"
         )}

      :not_authorise ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("You are not authorised to perform this action"))}
    end
  end

  defp save(socket, :edit, params) do
    case StdInterface.update(
           Account,
           "account",
           socket.assigns.form.data,
           params,
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, ac} ->
        {:noreply,
         socket
         |> push_navigate(
           to: ~p"/companies/#{socket.assigns.current_company.id}/accounts/#{ac.id}/edit"
         )
         |> put_flash(:info, "#{gettext("Account updated successfully.")}")}

      {:error, failed_operation, changeset, _} ->
        {:noreply,
         socket
         |> assign(form: to_form(changeset))
         |> put_flash(
           :error,
           "#{gettext("Failed")} #{failed_operation}. #{list_errors_to_string(changeset.errors)}"
         )}

      :not_authorise ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("You are not authorised to perform this action"))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="w-4/12 mx-auto border rounded-lg border-yellow-500 bg-yellow-100 p-4">
      <p class="w-full text-3xl text-center font-medium"><%= @page_title %></p>
      <.form
        for={@form}
        id="account-form"
        autocomplete="off"
        phx-change="validate"
        phx-submit="save"
        class="w-full"
      >
        <.input
          readonly={FullCircle.Accounting.is_default_account?(@form.data)}
          field={@form[:name]}
          label={gettext("Account Name")}
        />

        <.input
          disabled={FullCircle.Accounting.is_default_account?(@form.data)}
          field={@form[:account_type]}
          label={gettext("Account Type")}
          type="select"
          options={FullCircle.Accounting.account_types()}
        />

        <.input field={@form[:descriptions]} label={gettext("Descriptions")} type="textarea" />

        <div class="flex justify-center gap-x-1 mt-1">
          <.form_action_button
            form={@form}
            live_action={@live_action}
            current_company={@current_company}
            type="accounts"
          />
          <%= if @live_action == :edit and
                 FullCircle.Authorization.can?(@current_user, :delete_account, @current_company) do %>
            <.delete_confirm_modal
              id="delete-account"
              msg1={gettext("All Account Transactions, will be LOST!!!")}
              msg2={gettext("Cannot Be Recover!!!")}
              confirm={
                JS.push("delete", target: "#account-form") |> JS.hide(to: "#delete-account-modal")
              }
            />
          <% end %>
          <.live_component
            :if={@live_action == :edit}
            module={FullCircleWeb.LogLive.Component}
            current_company={@current_company}
            id={"log_#{@id}"}
            show_log={false}
            entity="accounts"
            entity_id={@id}
          />
        </div>
      </.form>
    </div>
    """
  end
end
