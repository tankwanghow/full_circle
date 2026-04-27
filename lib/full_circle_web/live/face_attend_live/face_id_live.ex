defmodule FullCircleWeb.FaceIdLive do
  use FullCircleWeb, :live_view

  alias FullCircle.HR
  alias FullCircle.HR.EmployeePhoto
  alias FullCircle.StdInterface
  alias Phoenix.PubSub

  @photo_cap 30

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
     |> push_event("faceIDDescriptors", %{
       descriptors: FullCircle.HR.get_face_id_descriptors(socket.assigns.current_company.id)
     })}
  end

  @impl true
  def handle_event("get_face_photo", %{"photo_id" => photo_id}, socket) do
    photo = FullCircle.HR.get_face_id_photo(photo_id)

    {:noreply,
     socket
     |> push_event("facePhoto", %{photo: photo})}
  end

  @impl true
  def handle_event("save_attendence", %{"employee_id" => emp_id, "flag" => flag} = params, socket) do
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
          maybe_learn(emp_id, params, socket)
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

  # Online learning: when face_id matched with high confidence (≥0.80, gated
  # client-side) we receive the live embedding + cropped face. Save it as a new
  # reference photo and prune oldest so the library stays at @photo_cap.
  defp maybe_learn(emp_id, %{"learn_discriptor" => discriptor, "learn_photo" => photo}, socket)
       when is_list(discriptor) and is_binary(photo) do
    com = socket.assigns.current_company
    user = socket.assigns.current_user

    # Persist the learned photo and prune. Intentionally do NOT broadcast
    # :new_photo / :delete_photo here — that would force every active face_id
    # session to rebuild its descriptor cache after every punch, which is
    # expensive at scale. Learned photos are picked up on the next natural
    # refresh (manual enroll/delete, page reload, or "Scan Face" click).
    case StdInterface.create(
           EmployeePhoto,
           "employee_photo",
           %{
             "photo_descriptor" => discriptor,
             "photo_data" => photo,
             "photo_type" => "png",
             "flag" => "learned",
             "employee_id" => emp_id
           },
           com,
           user
         ) do
      {:ok, _saved} ->
        HR.prune_employee_photos(emp_id, com.id, @photo_cap)

      _ ->
        :noop
    end
  end

  defp maybe_learn(_emp_id, _params, _socket), do: :noop

  @impl true
  def handle_info({:new_photo, _data}, socket) do
    {:noreply,
     socket
     |> push_event("faceIDDescriptors", %{
       descriptors: FullCircle.HR.get_face_id_descriptors(socket.assigns.current_company.id)
     })}
  end

  @impl true
  def handle_info({:delete_photo, _id}, socket) do
    {:noreply,
     socket
     |> push_event("faceIDDescriptors", %{
       descriptors: FullCircle.HR.get_face_id_descriptors(socket.assigns.current_company.id)
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
          <div id="in_out" class="flex mt-1 gap-2 items-center" style="display: none;">
            <button id="inBtn" class="w-2/5 h-20 text-4xl green button">
              {gettext("IN")}
            </button>
            <div id="scanResultPhotos" class="w-1/5 flex justify-center"></div>
            <button id="outBtn" class="w-2/5 h-20 text-4xl orange button">
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
