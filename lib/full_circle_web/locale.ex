defmodule FullCircleWeb.Locale do
  import Plug.Conn

  def on_mount(:set_locale, _params, session, socket) do
    locale = if(session["locale"], do: session["locale"], else: "en")
    Gettext.put_locale(FullCircleWeb.Gettext, locale)
    {:cont, Phoenix.Component.assign(socket, :locale, locale)}
  end

  def set_locale(%{params: %{"locale" => locale}} = conn, _opts) when locale in ["zh", "en"] do
    setup_locale(conn, locale)
  end

  def set_locale(conn, _opts) do
    case get_session(conn, "locale") do
      nil ->
        setup_locale(conn, "en")

      locale ->
        setup_locale(conn, locale)
    end
  end

  defp setup_locale(conn, locale) do
    Gettext.put_locale(locale)

    conn
    |> put_session(:locale, locale)
    |> assign(:locale, locale)
  end
end
