defmodule FullCircleWeb.PunchAttendanceController do
  use FullCircleWeb, :controller
  alias FullCircle.PunchGate

  def create(conn, params) do
    case PunchGate.ingest_punch(conn.assigns.punch_device, params) do
      {:ok, ta} ->
        ta = FullCircle.Repo.preload(ta, :employee)

        conn
        |> put_status(:created)
        |> json(%{
          id: ta.id,
          employee_name: ta.employee.name,
          flag: ta.flag,
          punch_time: DateTime.to_iso8601(ta.punch_time)
        })

      {:error, :not_found} ->
        send_resp(conn, 404, "not found")

      {:error, :inactive} ->
        send_resp(conn, 422, "inactive")

      {:error, :duplicate} ->
        send_resp(conn, 409, "duplicate")

      {:error, :too_large} ->
        send_resp(conn, 413, "too large")

      {:error, :missing_photo} ->
        send_resp(conn, 422, "missing photo")

      {:error, :future} ->
        send_resp(conn, 422, "future")

      {:error, _} ->
        send_resp(conn, 422, "invalid")
    end
  end
end
