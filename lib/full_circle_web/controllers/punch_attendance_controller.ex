defmodule FullCircleWeb.PunchAttendanceController do
  use FullCircleWeb, :controller
  alias FullCircle.PunchGate

  def health(conn, _params) do
    send_resp(conn, :no_content, "")
  end

  def create(conn, params) do
    case PunchGate.ingest_punch(conn.assigns.punch_device, params) do
      {:ok, ta} ->
        ta = FullCircle.Repo.preload(ta, :employee)

        conn
        |> put_status(PunchGate.http_status_for(:accepted))
        |> json(%{
          id: ta.id,
          employee_name: ta.employee.name,
          flag: ta.flag,
          punch_time: DateTime.to_iso8601(ta.punch_time)
        })

      {:error, reason} ->
        send_resp(conn, PunchGate.http_status_for(reason), body_for(reason))
    end
  end

  defp body_for(:not_found), do: "not found"
  defp body_for(:inactive), do: "inactive"
  defp body_for(:duplicate), do: "duplicate"
  defp body_for(:too_large), do: "too large"
  defp body_for(:missing_photo), do: "missing photo"
  defp body_for(:future), do: "future"
  defp body_for(_), do: "invalid"
end
