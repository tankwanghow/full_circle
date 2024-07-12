defmodule FullCircleWeb.FileDownloadController do
  use FullCircleWeb, :controller

  def show(conn, %{"filename" => filename}) do
    send_download(conn, {:file, filename})
  end
end
