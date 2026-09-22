defmodule FullCircleWeb.ActiveCompanyController do
  use FullCircleWeb, :controller

  import FullCircleWeb.ActiveCompany, only: [put_active_company: 2]

  def create(conn, %{"id" => id}) do
    c = FullCircle.Sys.get_company!(id)

    conn
    |> put_active_company(c)
    |> redirect(to: ~p"/companies")
  end

  def delete(conn, _) do
    conn
    |> put_active_company(nil)
    |> redirect(to: ~p"/companies")
  end
end
