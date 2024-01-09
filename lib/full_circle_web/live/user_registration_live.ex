defmodule FullCircleWeb.UserRegistrationLive do
  use FullCircleWeb, :live_view

  alias FullCircle.UserAccounts
  alias FullCircle.UserAccounts.User

  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-xs">
      <.header class="text-center">
        <%= gettext("Register for an account") %>
        <:subtitle>
          <%= gettext("Already registered?") %>
          <.link navigate={~p"/users/log_in"} class="font-semibold text-brand hover:underline">
            <%= gettext("Log in") %>
          </.link>
          <%= gettext("to your account now.") %>
        </:subtitle>
      </.header>

      <div class="mx-auto max-w-xs text-center mt-3">
        <a :if={!@is_a_human} class="red button" phx-click="human">I am a human</a>
        <a :if={!@is_a_human} class="blue button">I am a bot</a>
      </div>

      <div :if={@is_a_human}>
        <.simple_form
          for={@form}
          id="registration_form"
          phx-submit="save"
          phx-change="validate"
          phx-trigger-action={@trigger_submit}
          action={~p"/users/log_in?_action=registered"}
          method="post"
        >
          <.error :if={@check_errors}>
            <%= gettext("Oops, something went wrong! Please check the errors below.") %>
          </.error>

          <.input field={@form[:email]} type="email" label={gettext("Email")} required />
          <.input field={@form[:password]} type="password" label={gettext("Password")} required />

          <:actions>
            <.button phx-disable-with={gettext("Creating account...")} class="w-full">
              <%= gettext("Create an account") %>
            </.button>
          </:actions>
        </.simple_form>
      </div>
    </div>
    """
  end

  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(page_title: gettext("Register"))
      |> assign(is_a_human: false)

    {:ok, socket}
  end

  def handle_event("save", %{"user" => user_params}, socket) do
    case UserAccounts.register_user(user_params) do
      {:ok, user} ->
        {:ok, _} =
          UserAccounts.deliver_user_confirmation_instructions(
            user,
            &url(~p"/users/confirm/#{&1}")
          )

        changeset = UserAccounts.change_user_registration(user)
        {:noreply, socket |> assign(trigger_submit: true) |> assign_form(changeset)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, socket |> assign(check_errors: true) |> assign_form(changeset)}
    end
  end

  def handle_event("validate", %{"user" => user_params}, socket) do
    changeset = UserAccounts.change_user_registration(%User{}, user_params)
    {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
  end

  def handle_event("human", _, socket) do
    changeset = UserAccounts.change_user_registration(%User{})

    socket =
      socket
      |> assign(trigger_submit: false, check_errors: false)
      |> assign(page_title: gettext("Register"))
      |> assign(is_a_human: true)
      |> assign_form(changeset)

    {:noreply, socket}
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    form = to_form(changeset, as: "user")

    if changeset.valid? do
      assign(socket, form: form, check_errors: false)
    else
      assign(socket, form: form)
    end
  end
end
