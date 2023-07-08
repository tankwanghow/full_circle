defmodule FullCircleWeb.UserLive.Index do
  use FullCircleWeb, :live_view
  alias FullCircle.Sys

  @impl true
  def render(assigns) do
    ~H"""
    <div class="w-6/12 mx-auto">
      <p class="w-full text-2xl text-center font-bold"><%= @page_title %></p>
      <div class="flex justify-center gap-x-1">
        <.link navigate={~p"/companies/#{@current_company.id}/users/new"} class="text-xl mb-2 nav-btn">
          🧑<%= gettext("Add User") %>
        </.link>
      </div>
      <%= for u <- @users do %>
        <.form
          :let={f}
          for={%{}}
          as={:user_list}
          id={"user-#{u.id}"}
          phx-change="update_role"
          autocomplete="off"
        >
          <div class="shadow p-4 m-2 rounded bg-indigo-100 text-center text-xl">
            <span id={"new_user_password_#{u.id}"} class="text-gray-500 m-3">
              <%= if u.email != @current_user.email  do %>
                <%= if @new_password_id == u.id do %>
                  <span>Password reset to </span><span class="font-bold text-emerald-600"><%= @new_password %></span>
                <% else %>
                  <.link
                    href="#"
                    id={"reset_user_password_#{u.id}"}
                    phx-click="reset_password"
                    phx-value-id={u.id}
                    class="nav-btn"
                  >
                    🔏<span class="font-bold"><%= gettext("Reset Password") %></span>
                  </.link>
                <% end %>
              <% end %>
            </span>
            <span class="email font-mono font-bold"><%= u.email %></span>
            <span>
              <%= if u.email == @current_user.email do %>
                <%= gettext("is") %> <span class="text-amber-700"><%= u.role %></span>
              <% else %>
                <%= gettext("is") %>
                <%= Phoenix.HTML.Form.hidden_input(f, :id, value: u.id) %>
                <%= Phoenix.HTML.Form.select(f, :role, FullCircle.Authorization.roles(),
                  class: "rounded py-[1px] pl-[2px] pr-[40px] border-0 bg-indigo-50 text-xl",
                  value: u.role,
                  phx_page_loading: true
                ) %>
              <% end %>
            </span>
          </div>
        </.form>
      <% end %>
    </div>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("User List"))
     |> assign(:new_password_id, nil)
     |> assign(:new_password, nil)
     |> get_user_list()}
  end

  @impl true
  def handle_event("update_role", %{"user_list" => params}, socket) do
    case Sys.change_user_role_in(
           socket.assigns.current_company,
           params["id"],
           params["role"],
           socket.assigns.current_user
         ) do
      {:ok, _cu} ->
        {:noreply,
         socket
         |> get_user_list()
         |> put_flash(
           :info,
           gettext("Successfully updated user role to ") <> params["role"]
         )}

      {:error, _cs} ->
        {:noreply,
         socket
         |> get_user_list()
         |> put_flash(
           :error,
           gettext("Failed to change user to ") <> params["role"]
         )}
    end
  end

  @impl true
  def handle_event("reset_password", %{"id" => id}, socket) do
    user = FullCircle.UserAccounts.get_user!(id)

    case FullCircle.Sys.reset_user_password(
           user,
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, user, pwd} ->
        {:noreply,
         socket
         |> assign(:new_password_id, user.id)
         |> assign(:new_password, pwd)}

      {:error, _} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           gettext("Failed Reset Password")
         )}
    end
  end

  @impl true
  def handle_event("show_all", _, socket) do
    {:noreply, get_user_list(socket)}
  end

  @impl true
  def handle_event("show_active", _, socket) do
    {:noreply, get_user_list(socket)}
  end

  defp get_user_list(socket) do
    socket
    |> assign(
      :users,
      Sys.get_company_users(socket.assigns.current_company, socket.assigns.current_user)
    )
  end
end
