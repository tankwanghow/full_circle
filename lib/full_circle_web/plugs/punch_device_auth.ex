defmodule FullCircleWeb.PunchDeviceAuth do
  import Plug.Conn
  alias FullCircle.PunchGate

  def init(opts), do: opts

  def call(conn, _opts) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, device} <- PunchGate.authenticate_device(token) do
      conn
      |> assign(:punch_device, device)
      |> assign(:current_company, device.company)
    else
      {:revoked, device} ->
        # POSTs only. This plug also fronts GET /api/punch/health, which the
        # scanner pings every 20 seconds — logging those would write thousands
        # of rows a day per revoked phone and bury the punch worth seeing.
        if conn.method == "POST", do: PunchGate.log_revoked_attempt(device, conn.params)
        unauthorized(conn)

      _ ->
        unauthorized(conn)
    end
  end

  defp unauthorized(conn) do
    conn
    |> send_resp(:unauthorized, "No access for you")
    |> halt()
  end
end
