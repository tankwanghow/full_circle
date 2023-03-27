defmodule FullCircleWeb.ActiveCompanyController do
  use FullCircleWeb, :controller

  def create(conn, %{"id" => id}) do
    c = FullCircle.Sys.get_company!(id)

    conn
    |> put_session(:current_company, c)
    |> redirect(to: ~p"/companies")
  end

  def delete(conn, _) do
    conn
    |> put_session(:current_company, nil)
    |> redirect(to: ~p"/companies")
  end
end
