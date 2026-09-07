defmodule FullCircleWeb.PunchDeviceAuth do
  import Plug.Conn
  alias FullCircle.PunchGate

  def init(opts), do: opts

  def call(conn, _opts) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         %{} = device <- PunchGate.get_active_device_by_token(token) do
      conn
      |> assign(:punch_device, device)
      |> assign(:current_company, device.company)
    else
      _ ->
        conn
        |> send_resp(:unauthorized, "No access for you")
        |> halt()
    end
  end
end
