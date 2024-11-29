defmodule FullCircleWeb.TimeAttendLive.PunchCamera do
  use FullCircleWeb, :live_view

  alias FullCircle.HR

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(full_screen_app?: true)}
  end

  @impl true
  def handle_event("qr-code-scanned", params, socket) do
    emp_id = params["decodedText"] || "Not Found!!"

    result =
      try do
        emp =
          HR.get_employee!(
            emp_id,
            socket.assigns.current_company,
            socket.assigns.current_user
          )

        if emp.status != "Active" do
          %{decodedText: emp_id, status: :error, msg: "Employee Not Acvtive"}
        else
          %{decodedText: emp_id, status: :success, msg: emp.name}
        end
      rescue
        _e ->
          %{decodedText: emp_id, status: :error, msg: "Not Found!!"}
      end

    {:noreply, socket |> push_event("returnScanResult", result)}
  end

  @impl true
  def handle_event(
        "punch_in",
        %{"employee_id" => emp_id, "gps_long" => long, "gps_lat" => lat},
        socket
      ) do
    result =
      punched(
        %{
          employee_id: emp_id,
          flag: "IN",
          gps_long: long,
          gps_lat: lat
        },
        socket
      )

    {:noreply, socket |> push_event("punchResult", result)}
  end

  @impl true
  def handle_event(
        "punch_out",
        %{"employee_id" => emp_id, "gps_long" => long, "gps_lat" => lat},
        socket
      ) do
    result =
      punched(
        %{
          employee_id: emp_id,
          flag: "OUT",
          gps_long: long,
          gps_lat: lat
        },
        socket
      )

    {:noreply, socket |> push_event("punchResult", result)}
  end

  defp punched(data, socket) do
    case HR.create_time_attendence_by_punch(
           %{
             employee_id: data.employee_id,
             punch_time: Timex.now(),
             flag: data.flag,
             company_id: socket.assigns.current_company.id,
             user_id: socket.assigns.current_user.id,
             input_medium: "WebCam",
             gps_long: data.gps_long,
             gps_lat: data.gps_lat
           },
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, _ta} ->
        %{decodedText: "Good", status: :success, msg: data.flag}

      {:error, changeset} ->
        %{
          status: :error,
          msg:
            Enum.map_join(changeset.errors, fn {field, {msg, _}} ->
              "#{Atom.to_string(field)}: #{msg}"
            end),
          decodedText: "Problem!!"
        }

      :not_authorise ->
        %{decodedText: "", status: :error, msg: "Not Allowed!!"}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="punch-camera" phx-hook="punchCamera" class="mx-auto w-11/12">
      <div class="text-green-600 text-center font-bold">
        <%= @current_company.name %>
      </div>
      <div id="clock" class="text-blue-800 text-center font-bold"></div>

      <div id="camera" class="w-11/12 mx-auto mb-2" phx-update="ignore" style="display: block;" />

      <div
        id="scanned-result"
        class="w-11/12 mx-auto h-72 p-4 bg-sky-400 rounded-xl border-2"
        phx-update="ignore"
        style="display: none;"
      >
        <div id="decodedText" class="text-center mt-20 text-xs" />
        <div id="msg" class="text-2xl text-center font-bold align-middle" />
        <div id="spinner" class="w-5 mx-auto" style="display: none;">
          <svg
            class="animate-spin -ml-1 mr-3 h-5 w-5 text-white"
            xmlns="http://www.w3.org/2000/svg"
            fill="none"
            viewBox="0 0 24 24"
          >
            <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4">
            </circle>
            <path
              class="opacity-75"
              fill="currentColor"
              d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"
            >
            </path>
          </svg>
        </div>
      </div>

      <div
        id="in_out"
        class="flex mt-3 gap-2 text-4xl font-bold w-11/12 mx-auto"
        style="display: none;"
      >
        <button id="outBtn" class="w-1/2 h-28 red button">
          <%= gettext("OUT") %>
        </button>
        <button id="inBtn" class="w-1/2 h-28 blue button">
          <%= gettext("IN") %>
        </button>
      </div>

      <div id="backBtn" class="text-center mt-4" style="display: block;">
        <.link navigate={~p"/companies/#{@current_company.id}/dashboard"} class="red button">
          <%= gettext("Back") %>
        </.link>
      </div>

      <audio id="bad-sound" src="/sounds/beep-error.mp3" type="audio/mpeg"></audio>
      <audio id="good-sound" src="/sounds/beep.mp3" type="audio/mpeg"></audio>
    </div>
    """
  end
end
