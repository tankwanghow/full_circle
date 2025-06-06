defmodule FullCircleWeb.UserResetPasswordLive do
  use FullCircleWeb, :live_view

  alias FullCircle.UserAccounts

  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-sm">
      <.header class="text-center">{gettext("Reset Password")}</.header>

      <.simple_form
        for={@form}
        id="reset_password_form"
        phx-submit="reset_password"
        phx-change="validate"
      >
        <.error :if={@form.errors != []}>
          {gettext("Oops, something went wrong! Please check the errors below.")}
        </.error>

        <.input field={@form[:password]} type="password" label={gettext("New password")} required />
        <.input
          field={@form[:password_confirmation]}
          type="password"
          label={gettext("Confirm new password")}
          required
        />
        <:actions>
          <.button phx-disable-with={gettext("Resetting...")} class="w-full">
            {gettext("Reset Password")}
          </.button>
        </:actions>
      </.simple_form>

      <p class="text-center text-sm mt-4">
        <.link href={~p"/users/register"}>{gettext("Register")}</.link>
        | <.link href={~p"/users/log_in"}>{gettext("Log in")}</.link>
      </p>
    </div>
    """
  end

  def mount(params, _session, socket) do
    socket = assign_user_and_token(socket, params)

    form_source =
      case socket.assigns do
        %{user: user} ->
          UserAccounts.change_user_password(user)

        _ ->
          %{}
      end

    {:ok, assign_form(socket, form_source), temporary_assigns: [form: nil]}
  end

  # Do not log in the user after reset password to avoid a
  # leaked token giving the user access to the account.
  def handle_event("reset_password", %{"user" => user_params}, socket) do
    case UserAccounts.reset_user_password(socket.assigns.user, user_params) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Password reset successfully."))
         |> redirect(to: ~p"/users/log_in")}

      {:error, _, changeset, _} ->
        {:noreply, assign_form(socket, Map.put(changeset, :action, :insert))}
    end
  end

  def handle_event("validate", %{"user" => user_params}, socket) do
    changeset = UserAccounts.change_user_password(socket.assigns.user, user_params)
    {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
  end

  defp assign_user_and_token(socket, %{"token" => token}) do
    if user = UserAccounts.get_user_by_reset_password_token(token) do
      assign(socket, user: user, token: token)
    else
      socket
      |> put_flash(:error, gettext("Reset password link is invalid or it has expired."))
      |> redirect(to: ~p"/")
    end
  end

  defp assign_form(socket, %{} = source) do
    assign(socket, :form, to_form(source, as: "user"))
    |> assign(page_title: gettext("Reset Password"))
  end
end
