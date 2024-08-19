defmodule FullCircleWeb.ActiveCompany do
  use FullCircleWeb, :verified_routes
  import Plug.Conn
  import Phoenix.Controller
  require FullCircleWeb.Gettext

  def on_mount(:assign_active_company, _params, session, socket) do
    {:cont,
     socket
     |> Phoenix.Component.assign(:current_company, session["current_company"])
     |> Phoenix.Component.assign(:current_role, session["current_role"])
     |> Phoenix.Component.assign(:full_screen_app?, session["full_screen_app?"])}
  end

  def set_active_company(%{params: %{"company_id" => url_company_id}} = conn, _opts) do
    session_company_id = Util.attempt(get_session(conn, "current_company"), :id) || -1

    if session_company_id != url_company_id do
      if conn.assigns.current_user do
        cu = FullCircle.Sys.get_company_user(url_company_id, conn.assigns.current_user.id)

        if cu != nil do
          c = FullCircle.Sys.get_company!(cu.company_id)

          conn
          |> put_session(:current_role, cu.role)
          |> put_session(:current_company, c)
          |> put_session(:full_screen_app?, false)
          |> assign(:current_role, cu.role)
          |> assign(:current_company, c)
          |> assign(:full_screen_app?, false)
        else
          conn
          |> put_flash(:error, FullCircleWeb.Gettext.gettext("Not Authorise."))
          |> redirect(to: "/")
          |> halt()
        end
      else
        conn
      end
    else
      conn
    end
  end

  def set_active_company(conn, _opts) do
    conn
    |> assign(:current_role, get_session(conn, "current_role"))
    |> assign(:current_company, get_session(conn, "current_company"))
    |> assign(:full_screen_app?, get_session(conn, "full_screen_app?"))
  end
end
