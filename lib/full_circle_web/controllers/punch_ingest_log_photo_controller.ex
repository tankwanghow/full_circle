defmodule FullCircleWeb.PunchIngestLogPhotoController do
  @moduledoc """
  Serves one reject/duplicate face from `punch_ingest_logs`.

  Separate from `PunchPhotoController` on purpose: this one is role-gated, and
  an unauthorised viewer must get a bare **403**, never a redirect — an `<img>`
  that follows a dashboard redirect renders HTML into an image slot.
  """
  use FullCircleWeb, :controller

  alias FullCircle.Authorization
  alias FullCircle.PunchGate.PunchIngestLog
  alias FullCircle.{Repo, Sys}

  def show(conn, %{"id" => id, "company_id" => company_id}) do
    user = conn.assigns.current_user

    # The URL segment is the authority, not conn.assigns.current_company:
    # set_active_company/2 assigns nothing when the session company already
    # matches the URL, which is the normal path to this image.
    case member_company(company_id, user) do
      nil ->
        send_resp(conn, 404, "not found")

      company ->
        if Authorization.can?(user, :view_punch_ingest_log, company) do
          send_log_photo(conn, company_id, id)
        else
          send_resp(conn, 403, "forbidden")
        end
    end
  end

  defp member_company(company_id, user) do
    case Sys.get_company_user(company_id, user.id) do
      nil -> nil
      cu -> Sys.get_company!(cu.company_id)
    end
  end

  defp send_log_photo(conn, company_id, id) do
    log =
      case Ecto.UUID.cast(id) do
        {:ok, uuid} -> Repo.get_by(PunchIngestLog, id: uuid, company_id: company_id)
        :error -> nil
      end

    if is_nil(log) or is_nil(log.photo_path) do
      send_resp(conn, 404, "not found")
    else
      abs = Path.join(Application.get_env(:full_circle, :uploads_dir), log.photo_path)

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
