defmodule FullCircleWeb.TimeAttendLive.PunchCamera do
  use FullCircleWeb, :live_view

  alias FullCircle.HR

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(status: :waiting)
     |> assign(full_screen_app?: true)
     |> assign(flag: "IN")
     |> assign(page_title: gettext("Attendence Camera"))
     |> assign(shift_id: "")
     |> assign(valid?: false)
     |> assign(last_shifts: HR.last_shift(6, socket.assigns.current_company.id))}
  end

  @impl true
  def handle_event("qr-code-scanned", params, socket) do
    employee_id = params["decodedText"] || "Not Found!!"

    socket =
      socket
      |> assign(gps_long: params["gps_long"] || 182)
      |> assign(gps_lat: params["gps_lat"] || 182)

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
            socket |> assign(status: :not_found) |> assign(msg: employee_id)

          emp.status != "Active" ->
            socket |> assign(status: :error) |> assign(msg: emp.status)

          true ->
            {status, msg} = punch_in(emp, socket)

            socket
            |> assign(employee: emp)
            |> assign(status: status)
            |> assign(msg: msg)
        end

      {:noreply, socket}
    rescue
      _e ->
        {:noreply, socket |> assign(status: :error) |> assign(msg: employee_id)}
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

  @impl true
  def handle_event(
        "validate",
        %{"_target" => ["shift_form", "shift_id"], "shift_form" => %{"shift_id" => id}},
        socket
      ) do
    if id != "" do
      {:noreply, socket |> assign(valid?: true)}
    else
      {:noreply, socket |> assign(valid?: false)}
    end
  end

  @impl true
  def handle_event("shift_submit", %{"shift_form" => %{"shift_id" => id}}, socket) do
    {:noreply,
     socket |> assign(shift_id: (Timex.today() |> Timex.format!("%Y%m%d-", :strftime)) <> id)}
  end

  @impl true
  def handle_event("continue_shift", %{"shift" => shift_id}, socket) do
    {:noreply, socket |> assign(shift_id: shift_id)}
  end

  defp punch_in(employee, socket) do
    case HR.create_time_attendence_by_punch(
           %{
             employee_id: employee.id,
             punch_time: Timex.now(),
             flag: socket.assigns.flag,
             company_id: socket.assigns.current_company.id,
             user_id: socket.assigns.current_user.id,
             input_medium: "WebCam",
             gps_long: socket.assigns.gps_long,
             gps_lat: socket.assigns.gps_lat,
             shift_id: socket.assigns.shift_id
           },
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, ta} ->
        {:success, "#{ta.shift_id}"}

      {:error, changeset} ->
        {:error,
         Enum.map_join(changeset.errors, fn {field, {msg, _}} ->
           "#{Atom.to_string(field)}: #{msg}"
         end)}

      :not_authorise ->
        {:not_authorise, "Not Authorise!"}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="punch-camera" class="mx-auto">
      <div class="text-xl text-center font-bold">
        <%= @current_company.name %>
      </div>
      <div class="mx-auto w-[90%] text-2xl text-center mb-2 border-y-4 border-green-800 bg-green-200">
        <span class="text-blue-600" id="date" /> <span class="text-amber-800" id="clock" />
      </div>
      <div :if={@shift_id == ""}>
        <.form
          for={%{}}
          id="shift-form"
          phx-submit="shift_submit"
          phx-change="validate"
          autocomplete="off"
          class="max-w-2xl mx-auto"
        >
          <div class="grid grid-cols-12 gap-1 mx-5">
            <div class="col-span-4 text-xl mt-1 font-mono tracking-tighter">
              <%= Timex.today() |> Timex.format!("%Y%m%d", :strftime) %>
            </div>
            <div class="col-span-4">
              <.input
                phx-debounce="300"
                name="shift_form[shift_id]"
                type="text"
                id="shift_form_shift_id"
                value=""
              />
            </div>
            <div class="col-span-4 -mt-1">
              <.button disabled={!@valid?}>Start Shift</.button>
            </div>
          </div>
        </.form>
        <div class="text-center mt-3 text-red-500 font-bold text-2xl">
          Last 6 Shifts
        </div>
        <%= for obj <- @last_shifts do %>
          <div class="mt-3 text-center text-2xl">
            <.link
              phx-value-shift={obj.shift}
              phx-click={:continue_shift}
              class="blue button"
              id={"continue_#{obj.shift}"}
            >
              Continue <span class="font-bold font-mono"><%= obj.shift %></span>
            </.link>
          </div>
        <% end %>
      </div>

      <div :if={@shift_id != ""}>
        <div
          :if={@flag == "OUT"}
          phx-click="in_out"
          class="mb-1 font-bold text-xl mx-auto w-[50%] button blue"
        >
          OUT <span aria-hidden="true">→</span> IN
        </div>
        <div
          :if={@flag == "IN"}
          phx-click="in_out"
          class="mb-2 font-bold text-xl mx-auto text-center w-[50%] button red"
        >
          IN <span aria-hidden="true">→</span> OUT
        </div>
        <div class={"mx-auto w-[80%] text-center border-y-2 #{if(@flag == "IN", do: "bg-blue-200 border-blue-400", else: "bg-red-200 border-red-600")} mb-2"}>
          <div class="text-2xl font-bold"><%= @flag %></div>
          <div :if={@flag == "IN"} class="font-bold font-mono text-cyan-600"><%= @shift_id %></div>
        </div>

        <div id="qr-reader" phx-update="ignore" class="w-[90%] mx-auto mb-2" phx-hook="QR_Scanner">
        </div>
        <div
          :if={@status == :success}
          id="qr-reply"
          phx-hook="QR_Reply"
          class="w-[80%] text-center text-2xl mx-auto border-y-4 bg-green-200 border-green-600"
        >
          <audio autoplay>
            <source src="/sounds/beep.mp3" type="audio/mpeg" />
          </audio>
          <%= @employee.name %>
          <%= @employee.id_no %>
          <div :if={@flag == "IN"} class="text-2xl text-green-500">
            Punched <span class="font-bold"><%= @flag %></span>
            Shift <span class="font-bold"><%= @msg %></span>
          </div>
          <div :if={@flag == "OUT"} class="text-2xl text-red-500">
            Punched <span class="font-bold"><%= @flag %></span>
            Shift <span class="font-bold"><%= @msg %></span>
          </div>
        </div>
        <div
          :if={@status == :waiting}
          id="qr-reply"
          phx-hook="QR_Reply"
          class="w-[80%] text-center text-2xl mx-auto border-y-4 bg-amber-200 border-amber-600"
        >
          Scan Employee QR
        </div>
        <div
          :if={@status == :error}
          id="qr-reply"
          phx-hook="QR_Reply"
          class="w-[80%] text-center text-2xl mx-auto border-y-4 bg-rose-200 border-rose-600"
        >
          <audio autoplay>
            <source src="/sounds/beep-error.mp3" type="audio/mpeg" />
          </audio>
          QR ERROR!!
          <div><%= @msg %></div>
        </div>
        <div
          :if={@status == :not_found}
          id="qr-reply"
          phx-hook="QR_Reply"
          class="w-[80%] text-center text-2xl mx-auto border-y-4 bg-rose-200 border-rose-600"
        >
          <audio autoplay>
            <source src="/assets/beep-error.mp3" type="audio/mpeg" />
          </audio>
          Employee Not Found!!!
          <div class="text-lg"><%= @msg %></div>
        </div>
      </div>
      <div class="text-center mt-4">
        <.link navigate={~p"/companies/#{@current_company.id}/dashboard"} class="red button">
          <%= gettext("Back") %>
        </.link>
      </div>
    </div>

    <script>
      function display_ct6() {
        var x = new Date();
        hours = addZero(x.getHours());
        var date = x.getFullYear() + "-" + addZero((x.getMonth() + 1)) + "-" + addZero(x.getDate());
        clock = hours + ":" +  addZero(x.getMinutes()) + ":" + addZero(x.getSeconds());
        document.getElementById('clock').innerHTML = clock;
        document.getElementById('date').innerHTML = date;
        display_c6();
      }

      function addZero(i) {
        if (i < 10) {i = "0" + i};  // add zero in front of numbers < 10
        return i;
      }

      function display_c6(){
        var refresh = 1000; // Refresh rate in milli seconds
        setTimeout('display_ct6()', refresh);
      }

      display_c6();
    </script>
    """
  end
end
