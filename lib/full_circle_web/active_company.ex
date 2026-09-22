defmodule FullCircleWeb.ActiveCompany do
  @moduledoc """
  Tracks which company the user is working in.

  Only the company **id** goes into the session. The session is a signed cookie:
  Plug hard-caps it at 4096 bytes, and nginx reads the response header block into
  a 4k `proxy_buffer_size`. A whole `%Company{}` drags the unbounded `settings`
  map along with it — the two forecast exclusion lists store an account UUID per
  excluded account — and on production that pushed `Set-Cookie` past both limits,
  so nginx answered every company-scoped page with `502 Bad Gateway` while the
  app itself was happily returning 200.

  Reading the row back per request also removes the stale-snapshot problem that
  `Sys.period_closed_through/1` had to work around by hand.
  """
  use FullCircleWeb, :verified_routes
  import Plug.Conn
  import Phoenix.Controller
  use Gettext, backend: FullCircleWeb.Gettext

  def on_mount(:assign_active_company, _params, session, socket) do
    company = company_from_session(session)

    einv_portal =
      if company && socket.assigns[:current_user] do
        FullCircle.EInvMetas.portal_base_url(company, socket.assigns.current_user)
      else
        "https://myinvois.hasil.gov.my"
      end

    {:cont,
     socket
     |> Phoenix.Component.assign(:current_company, company)
     |> Phoenix.Component.assign(:current_role, session["current_role"])
     |> Phoenix.Component.assign(:full_screen_app?, session["full_screen_app?"])
     |> Phoenix.Component.assign(:einv_portal, einv_portal)}
  end

  @doc """
  The active company for a LiveView `session` map, or `nil`.

  Loads the row — the session only names it.
  """
  def company_from_session(session) when is_map(session) do
    case active_company_id(session) do
      nil -> nil
      id -> FullCircle.Repo.get(FullCircle.Sys.Company, id)
    end
  end

  @doc """
  The active company for a `conn`, or `nil`.

  For plug pipelines, where the session has string keys.
  """
  def active_company(conn), do: conn |> get_session() |> company_from_session()

  # Sessions written before the company id replaced the struct still carry the
  # whole company. Honour them so a logged-in user is not bounced mid-session;
  # set_active_company/2 drops the key on the next company-scoped request.
  defp active_company_id(session) do
    case session["current_company_id"] do
      nil -> Util.attempt(session["current_company"], :id)
      id -> id
    end
  end

  def set_active_company(%{params: %{"company_id" => url_company_id}} = conn, _opts) do
    session_company_id = active_company_id(get_session(conn)) || -1

    if session_company_id == url_company_id do
      # Already active. Rewrite only a session left over from the release that
      # stored the struct — otherwise this company-scoped request, and every one
      # after it, would keep carrying the oversized cookie that caused the 502.
      if get_session(conn, "current_company") do
        put_active_company(conn, url_company_id)
      else
        conn
      end
    else
      if conn.assigns.current_user do
        cu = FullCircle.Sys.get_company_user(url_company_id, conn.assigns.current_user.id)

        if cu != nil do
          c = FullCircle.Sys.get_company!(cu.company_id)

          conn
          |> put_session(:current_role, cu.role)
          |> put_active_company(c)
          |> put_session(:full_screen_app?, false)
          |> assign(:current_role, cu.role)
          |> assign(:current_company, c)
          |> assign(:full_screen_app?, false)
        else
          conn
          |> put_flash(:error, gettext("Not Authorise."))
          |> redirect(to: "/")
          |> halt()
        end
      else
        conn
      end
    end
  end

  def set_active_company(conn, _opts) do
    conn
    |> assign(:current_role, get_session(conn, "current_role"))
    |> assign(:current_company, active_company(conn))
    |> assign(:full_screen_app?, get_session(conn, "full_screen_app?"))
  end

  @doc """
  Names `company` as the active one in the session.

  Deleting `:current_company` is what shrinks a session written by an older
  release back down; without it the oversized struct rides along forever.
  """
  def put_active_company(conn, nil) do
    conn
    |> delete_session(:current_company)
    |> put_session(:current_company_id, nil)
  end

  def put_active_company(conn, %{id: id}), do: put_active_company(conn, id)

  def put_active_company(conn, id) when is_binary(id) do
    conn
    |> delete_session(:current_company)
    |> put_session(:current_company_id, id)
  end
end
