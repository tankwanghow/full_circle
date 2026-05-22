defmodule FullCircleWeb.SharedDocumentController do
  use FullCircleWeb, :controller

  def expired(conn, _params) do
    conn
    |> put_layout(false)
    |> render(:expired)
  end
end
