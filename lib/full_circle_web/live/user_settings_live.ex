defmodule FullCircleWeb.UserSettingsLive do
  use FullCircleWeb, :live_view

  alias FullCircle.UserAccounts

  def render(assigns) do
    ~H"""
    <.header class="text-center">
      {gettext("User Settings")}
      <:subtitle>{gettext("Manage your account email address and password settings")}</:subtitle>
    </.header>

    <div class="w-3/12 mx-auto space-y-5 divide-y">
      <div>
        <.simple_form
          for={@email_form}
          id="email_form"
          phx-submit="update_email"
          phx-change="validate_email"
        >
          <.input field={@email_form[:email]} type="email" label={gettext("Email")} required />
          <.input
            field={@email_form[:current_password]}
            name="current_password"
            id="current_password_for_email"
            type="password"
            label={gettext("Current password")}
            value={@email_form_current_password}
            required
          />
          <:actions>
            <.button phx-disable-with={gettext("Changing...")}>
              {gettext("Change Email")}
            </.button>
          </:actions>
        </.simple_form>
      </div>
      <div>
        <.simple_form
          for={@password_form}
          id="password_form"
          action={~p"/users/log_in?_action=password_updated"}
          method="post"
          phx-change="validate_password"
          phx-submit="update_password"
          phx-trigger-action={@trigger_submit}
        >
          <.input
            field={@password_form[:email]}
            type="hidden"
            id="hidden_user_email"
            value={@current_email}
          />
          <.input
            field={@password_form[:password]}
            type="password"
            label={gettext("New password")}
            required
          />
          <.input
            field={@password_form[:password_confirmation]}
            type="password"
            label={gettext("Confirm new password")}
          />
          <.input
            field={@password_form[:current_password]}
            name="current_password"
            type="password"
            label={gettext("Current password")}
            id="current_password_for_password"
            value={@current_password}
            required
          />
          <:actions>
            <.button phx-disable-with="Changing...">{gettext("Change Password")}</.button>
          </:actions>
        </.simple_form>
      </div>
    </div>
    """
  end

  def mount(%{"token" => token}, _session, socket) do
    socket =
      case UserAccounts.update_user_email(socket.assigns.current_user, token) do
        :ok ->
          put_flash(socket, :info, gettext("Email changed successfully."))

        :error ->
          put_flash(socket, :error, gettext("Email change link is invalid or it has expired."))
      end

    {:ok, push_navigate(socket, to: ~p"/users/settings")}
  end

  def mount(_params, _session, socket) do
    user = socket.assigns.current_user
    email_changeset = UserAccounts.change_user_email(user)
    password_changeset = UserAccounts.change_user_password(user)

    socket =
      socket
      |> assign(:full_screen_app?, false)
      |> assign(page_title: gettext("User Settings"))
      |> assign(:current_password, nil)
      |> assign(:email_form_current_password, nil)
      |> assign(:current_email, user.email)
      |> assign(:email_form, to_form(email_changeset))
      |> assign(:password_form, to_form(password_changeset))
      |> assign(:trigger_submit, false)

    {:ok, socket}
  end

  def handle_event("validate_email", params, socket) do
    %{"current_password" => password, "user" => user_params} = params

    email_form =
      socket.assigns.current_user
      |> UserAccounts.change_user_email(user_params)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, email_form: email_form, email_form_current_password: password)}
  end

  def handle_event("update_email", params, socket) do
    %{"current_password" => password, "user" => user_params} = params
    user = socket.assigns.current_user

    case UserAccounts.apply_user_email(user, password, user_params) do
      {:ok, applied_user} ->
        UserAccounts.deliver_user_update_email_instructions(
          applied_user,
          user.email,
          &url(~p"/users/settings/confirm_email/#{&1}")
        )

        info = gettext("A link to confirm your email change has been sent to the new address.")
        {:noreply, socket |> put_flash(:info, info) |> assign(email_form_current_password: nil)}

      {:error, changeset} ->
        {:noreply, assign(socket, :email_form, to_form(Map.put(changeset, :action, :insert)))}
    end
  end

  def handle_event("validate_password", params, socket) do
    %{"current_password" => password, "user" => user_params} = params

    password_form =
      socket.assigns.current_user
      |> UserAccounts.change_user_password(user_params)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, password_form: password_form, current_password: password)}
  end

  def handle_event("update_password", params, socket) do
    %{"current_password" => password, "user" => user_params} = params
    user = socket.assigns.current_user

    case UserAccounts.update_user_password(user, password, user_params) do
      {:ok, user} ->
        password_form =
          user
          |> UserAccounts.change_user_password(user_params)
          |> to_form()

        {:noreply, assign(socket, trigger_submit: true, password_form: password_form)}

      {:error, _, changeset, _} ->
        {:noreply, assign(socket, password_form: to_form(changeset))}
    end
  end
end
