defmodule FullCircleWeb.FileDownloadController do
  use FullCircleWeb, :controller

  def show(conn, %{"company_id" => com_id, "filename" => filename}) do
    path =
      Path.join([
        Application.get_env(:full_circle, :uploads_dir),
        com_id, filename
      ])

    send_download(conn, {:file, path})
  end
end
