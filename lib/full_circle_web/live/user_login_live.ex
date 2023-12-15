defmodule FullCircleWeb.UserLoginLive do
  use FullCircleWeb, :live_view

  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-xs">
      <.header class="text-center mb-0">
        <%= gettext("Log in to account") %>
      </.header>

      <div class="text-center -mb-4">
        <.link navigate={~p"/users/register"} class="font-semibold text-brand hover:underline">
          <%= gettext("Register for an account") %>
        </.link>
      </div>
      <.simple_form for={@form} id="login_form" action={~p"/users/log_in"} phx-update="ignore" class="w-[90%] mx-auto">
        <.input field={@form[:email]} type="email" label={gettext("Email")} required />
        <.input field={@form[:password]} type="password" label={gettext("Password")} required />

        <div class="flex flex-row flex-warp gap-2">
          <div class="w-[50%]">
            <.input field={@form[:remember_me]} type="checkbox" label={gettext("Keep me logged in")} />
          </div>
          <div class="w-[50%]">
            <.link href={~p"/users/reset_password"} class="text-sm font-semibold">
              <%= gettext("Forgot your password?") %>
            </.link>
          </div>
        </div>
        <:actions>
          <.button phx-disable-with={gettext("Signing in...")} class="w-full">
            <%= gettext("Sign in") %>
          </.button>
        </:actions>
      </.simple_form>
    </div>
    """
  end

  def mount(_params, _session, socket) do
    email = live_flash(socket.assigns.flash, :email)
    form = to_form(%{"email" => email}, as: "user")

    socket =
      socket
      |> assign(page_title: gettext("Sign in"))
      |> assign(form: form)

    {:ok, socket, temporary_assigns: [form: form]}
  end
end
