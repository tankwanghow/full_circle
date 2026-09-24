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

  @doc """
  Resolves the company named in the URL, for every company-scoped request.

  The membership check is NOT skipped when the session already names this
  company. The session is signed, not encrypted, so a session that names a
  company is not evidence that its holder may open it — nor that the role it
  carries is the role the database gives them. `CompanyUser` is the authority,
  and `Sys.user_company/2` excludes `disable`, so this must too or the plug and
  the query scoping disagree about who is allowed in.
  """
  def set_active_company(%{params: %{"company_id" => url_company_id}} = conn, _opts) do
    if conn.assigns[:current_user] do
      case company_membership(url_company_id, conn.assigns.current_user.id) do
        {:ok, company, role} -> sync_active_company(conn, company, role)
        :error -> refuse(conn)
      end
    else
      conn
    end
  end

  def set_active_company(conn, _opts) do
    conn
    |> assign(:current_role, get_session(conn, "current_role"))
    |> assign(:current_company, active_company(conn))
    |> assign(:full_screen_app?, get_session(conn, "full_screen_app?"))
  end

  defp company_membership(company_id, user_id) do
    # A path segment is whatever the caller typed; casting it keeps a malformed
    # id from raising Ecto.Query.CastError and turning into a 500.
    with {:ok, _} <- Ecto.UUID.cast(company_id),
         %{role: role} when role != "disable" <-
           FullCircle.Sys.get_company_user(company_id, user_id) do
      {:ok, FullCircle.Sys.get_company!(company_id), role}
    else
      _ -> :error
    end
  end

  defp sync_active_company(conn, company, role) do
    conn =
      conn
      |> assign(:current_role, role)
      |> assign(:current_company, company)

    if get_session(conn, "current_company_id") == company.id and
         get_session(conn, "current_role") == role and
         is_nil(get_session(conn, "current_company")) do
      # Nothing to correct — don't spend a Set-Cookie on every request.
      assign(conn, :full_screen_app?, get_session(conn, "full_screen_app?") || false)
    else
      conn
      |> put_active_company(company)
      |> put_session(:current_role, role)
      |> put_session(:full_screen_app?, false)
      |> assign(:full_screen_app?, false)
    end
  end

  defp refuse(conn) do
    conn
    |> put_flash(:error, gettext("Not Authorise."))
    |> redirect(to: "/")
    |> halt()
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
