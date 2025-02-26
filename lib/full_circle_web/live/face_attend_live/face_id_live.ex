defmodule FullCircleWeb.FaceIdLive do
  use FullCircleWeb, :live_view

  alias FullCircle.HR
  alias Phoenix.PubSub

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      PubSub.subscribe(
        FullCircle.PubSub,
        "#{socket.assigns.current_company.id}_refresh_face_id_data"
      )
    end

    {:ok,
     socket
     |> assign(page_title: "Face Id")
     |> assign(full_screen_app?: true)
     |> assign(photos: [])}
  end

  @impl true
  def handle_event("get_face_id_photos", _, socket) do
    {:noreply,
     socket
     |> push_event("faceIDPhotos", %{
       photos: FullCircle.HR.get_face_id_photos(socket.assigns.current_company.id)
     })}
  end

  @impl true
  def handle_event(
        "save_attendence",
        %{"employee_id" => emp_id, "flag" => flag},
        socket
      ) do
    result =
      case HR.create_time_attendence_by_punch(
             %{
               employee_id: emp_id,
               punch_time: Timex.now(),
               flag: flag,
               company_id: socket.assigns.current_company.id,
               user_id: socket.assigns.current_user.id,
               input_medium: "faceId"
             },
             socket.assigns.current_company,
             socket.assigns.current_user
           ) do
        {:ok, _ta} ->
          %{status: :success, msg: flag}

        {:error, changeset} ->
          %{
            status: :error,
            msg:
              Enum.map_join(changeset.errors, fn {field, {msg, _}} ->
                "#{Atom.to_string(field)}: #{msg}"
              end)
          }

        :not_authorise ->
          %{status: :error, msg: "Not Allowed!!"}
      end

    {:noreply, socket |> push_event("saveAttendenceResult", result)}
  end

  @impl true
  def handle_info({:new_photo, _data}, socket) do
    {:noreply,
     socket
     |> push_event("faceIDPhotos", %{
       photos: FullCircle.HR.get_face_id_photos(socket.assigns.current_company.id)
     })}
  end

  @impl true
  def handle_info({:delete_photo, _id}, socket) do
    {:noreply,
     socket
     |> push_event("faceIDPhotos", %{
       photos: FullCircle.HR.get_face_id_photos(socket.assigns.current_company.id)
     })}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="employee_info" class="text-center">
      <div id="clock" class="text-blue-800 text-center text-3xl"></div>
      <div id="faceID" phx-hook="FaceID" phx-update="ignore">
        <div
          id="statusBar"
          style="display: none"
          class="absolute inset-x-0 top-[350px] h-16 text-2xl font-bold"
        >
          Press Scan Face to Start...
        </div>
        <%!-- <.icon name="hero-arrow-path" class="ml-1 h-3 w-3 animate-spin" /> --%>
        <canvas id="canvas" class="mx-auto w-[98%] rounded-xl"></canvas>
        <video id="video" playsinline style="display: none" class="mb-1"></video>
        <div class="text-center">
          <select id="videoSelect" class="rounded h-8 py-1 pr-8" />
        </div>

        <div class="w-11/12 mx-auto">
          <div id="in_out" class="flex mt-1 gap-2" style="display: none;">
            <button id="inBtn" class="w-1/2 h-20 text-4xl green button">
              {gettext("IN")}
            </button>
            <button id="outBtn" class="w-1/2 h-20 text-4xl orange button">
              {gettext("OUT")}
            </button>
          </div>

          <button
            id="scanFace"
            class="mt-1 mx-auto w-1/2 h-20 blue button text-2xl"
            style="display: none;"
          >
            {gettext("Scan Face")}
          </button>
        </div>
        <div id="scanResultPhotos" class="mt-1 flex gap-1 mx-auto w-6/12"></div>
        <div id="log" class="text-center"></div>
      </div>
      <div class="text-center mt-10">
        <.link navigate={~p"/companies/#{@current_company.id}/dashboard"} class="orange button">
          {gettext("Back")}
        </.link>
      </div>
    </div>
    """
  end
end
