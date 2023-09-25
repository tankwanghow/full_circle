defmodule FullCircleWeb.TimeAttendLive.PunchCamera do
  use FullCircleWeb, :live_view
  alias FullCircle.HR

  @impl true
  def mount(params, _session, socket) do
    {:ok, socket |> assign(employee: %{name: "", id_no: ""})}
  end

  @impl true
  def handle_event("qr-code-scanned", params, socket) do
    employee_id = params["decodedText"]

    emp =
      if(is_nil(employee_id),
        do: nil,
        else:
          HR.get_employee!(
            employee_id,
            socket.assigns.current_company,
            socket.assigns.current_user
          )
      )

    {:noreply, socket |> assign(employee: emp) }
  end

  @impl true
  def handle_event("qr-code-scan-resume", params, socket) do
    {:noreply, socket |> assign(employee: %{name: "Scan Employee QR", id_no: ""})}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="text-3xl text-center">
      <%= @current_company.name %>
    </div>

    <div
      id="date"
      class="w-[80%] rounded-lg bg-green-400 mb-2 mx-auto border text-3xl border-green-800 text-center"
    />
    <div
      id="clock"
      class="w-[80%] rounded-lg bg-yellow-200 mb-2 mx-auto border text-3xl border-yellow-400 text-center"
    />

    <div id="qr-reader" phx-update="ignore" class="w-[80%] mx-auto mb-2" phx-hook="QR_Scanner"></div>
    <div
      id="qr-reply" phx-hook="QR_Reply"
      class="w-[80%] text-center text-3xl mx-auto border rounded-lg"
    >
      <%= @employee.name %>
      <%= @employee.id_no %>
    </div>

    <script>
      function display_ct6() {
        var x = new Date()
        var ampm = x.getHours( ) >= 12 ? ' PM' : ' AM';
        hours = x.getHours( ) % 12;
        hours = hours ? hours : 12;
        var date = x.getDate() + "-" + (x.getMonth() + 1) + "-" + x.getFullYear();
        clock = hours + ":" +  x.getMinutes() + ":" +  x.getSeconds() + ampm;
        document.getElementById('clock').innerHTML = clock;
        document.getElementById('date').innerHTML = date;
        display_c6();
      }

      function display_c6(){
        var refresh = 500; // Refresh rate in milli seconds
        setTimeout('display_ct6()', refresh);
      }

      display_c6();
    </script>
    """
  end
end
