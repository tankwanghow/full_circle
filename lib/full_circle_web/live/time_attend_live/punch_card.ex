defmodule FullCircleWeb.TimeAttendLive.PunchCamera do
  use FullCircleWeb, :live_view

  alias FullCircle.HR

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(status: :waiting)
     |> assign(flag: "IN")
     |> assign(page_title: gettext("Attendence Camera"))}
  end

  @impl true
  def handle_event("qr-code-scanned", params, socket) do
    employee_id = params["decodedText"] || "Not Found!!"

    try do
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

      socket =
        cond do
          is_nil(emp) ->
            socket |> assign(status: :not_found) |> assign(qr_code: employee_id)

          emp.status != "Active" ->
            socket |> assign(status: :error) |> assign(qr_code: emp.status)

          true ->
            {status, msg} = punch_in(emp, socket)
            socket |> assign(employee: emp) |> assign(status: status) |> assign(qr_code: msg)
        end

      {:noreply, socket}
    rescue
      e ->
        IO.inspect(e)
        {:noreply, socket |> assign(status: :error) |> assign(qr_code: employee_id)}
    end
  end

  @impl true
  def handle_event("qr-code-scan-resume", _params, socket) do
    {:noreply, socket |> assign(status: :waiting)}
  end

  @impl true
  def handle_event("in_out", _params, socket) do
    if(socket.assigns.flag == "IN") do
      {:noreply, socket |> assign(flag: "OUT")}
    else
      {:noreply, socket |> assign(flag: "IN")}
    end
  end

  defp punch_in(employee, socket) do
    case HR.create_time_attendence_by_punch(
           %{
             employee_id: employee.id,
             punch_time: Timex.now(),
             flag: socket.assigns.flag,
             company_id: socket.assigns.current_company.id,
             user_id: socket.assigns.current_user.id,
             input_medium: "PunchCamera"
           },
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, _ac} ->
        {:success, ""}

      {:error, changeset} ->
        {:error,
         Enum.map_join(changeset.errors, fn {field, {msg, _}} ->
           "#{Atom.to_string(field)}: #{msg}"
         end)}

      :not_authorise ->
        {:not_authorise, ""}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="text-2xl text-center mx-auto">
      <%= @current_company.name %>
    </div>

    <div
      class={"mx-auto w-[80%] text-2xl text-center #{if(@flag == "IN", do: "blue", else: "red")} button mb-2"}
      phx-click="in_out"
    >
      Punch <%= @flag %>
    </div>

    <div class="mx-auto w-[80%] text-2xl text-center">
      <span id="date" /> <span id="clock" />
    </div>

    <div id="qr-reader" phx-update="ignore" class="w-[80%] mx-auto mb-2" phx-hook="QR_Scanner"></div>
    <div
      :if={@status == :success}
      id="qr-reply"
      phx-hook="QR_Reply"
      class="w-[80%] text-center text-3xl mx-auto border rounded-lg bg-green-200 border-green-600"
    >
      <audio autoplay>
        <source src="/assets/beep.mp3" type="audio/mpeg" />
      </audio>
      <%= @employee.name %>
      <%= @employee.id_no %>
      <div :if={@flag == "IN"} class="text-6xl text-green-500">&#128512;<%= @flag %>&#128512;</div>
      <div :if={@flag == "OUT"} class="text-6xl text-red-500">&#128513;<%= @flag %>&#128513;</div>
    </div>
    <div
      :if={@status == :waiting}
      id="qr-reply"
      phx-hook="QR_Reply"
      class="w-[80%] text-center text-3xl mx-auto border rounded-lg bg-amber-200 border-amber-600"
    >
      Scan Employee QR
    </div>
    <div
      :if={@status == :error}
      id="qr-reply"
      phx-hook="QR_Reply"
      class="w-[80%] text-center text-3xl mx-auto border rounded-lg bg-rose-200 border-rose-600"
    >
      <audio autoplay>
        <source src="/assets/beep-error.mp3" type="audio/mpeg" />
      </audio>
      QR ERROR!!
      <div><%= @qr_code %></div>
    </div>
    <div
      :if={@status == :not_found}
      id="qr-reply"
      phx-hook="QR_Reply"
      class="w-[80%] text-center text-3xl mx-auto border rounded-lg bg-rose-200 border-rose-600"
    >
      <audio autoplay>
        <source src="/assets/beep-error.mp3" type="audio/mpeg" />
      </audio>
      Employee Not Found!!!
      <div class="text-lg"><%= @qr_code %></div>
    </div>
    <div class="text-center mt-5">
      <a onclick="history.back();" class="red button"><%= gettext("Back") %></a>
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
