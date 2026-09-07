defmodule FullCircleWeb.PunchPhotoController do
  use FullCircleWeb, :controller
  alias FullCircle.Repo
  alias FullCircle.HR.TimeAttend

  def show(conn, %{"id" => id, "company_id" => company_id}) do
    ta = Repo.get_by(TimeAttend, id: id, company_id: company_id)

    cond do
      is_nil(ta) or is_nil(ta.photo_path) ->
        send_resp(conn, 404, "not found")

      true ->
        abs = Path.join(Application.get_env(:full_circle, :uploads_dir), ta.photo_path)

        if File.exists?(abs) do
          conn
          |> put_resp_content_type("image/jpeg")
          |> send_file(200, abs)
        else
          send_resp(conn, 404, "not found")
        end
    end
  end
end
