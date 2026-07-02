defmodule FullCircleWeb.BundleController do
  use FullCircleWeb, :controller

  alias FullCircle.StatutoryConfig

  def export(conn, %{"company_id" => com_id}) do
    if authorized?(conn, com_id) do
      date = Date.utc_today()
      body = com_id |> StatutoryConfig.export_bundle(date) |> Jason.encode!(pretty: true)

      conn
      |> put_resp_content_type("application/json")
      |> put_resp_header(
        "content-disposition",
        ~s|attachment; filename="statutory_bundle_#{Date.to_iso8601(date)}.json"|
      )
      |> send_resp(200, body)
    else
      conn
      |> put_flash(:error, "Not authorized")
      |> redirect(to: "/companies/#{com_id}/dashboard")
    end
  end

  defp authorized?(conn, com_id) do
    user = conn.assigns.current_user
    company = FullCircle.Sys.get_company!(com_id)
    FullCircle.Authorization.can?(user, :manage_statutory_config, company)
  end
end