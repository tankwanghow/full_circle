defmodule FullCircleWeb.TakePhotoLive do
  use FullCircleWeb, :live_view

  alias FullCircle.HR.EmployeePhoto
  alias FullCircle.StdInterface
  alias Phoenix.PubSub

  @impl true
  def mount(%{"emp_id" => emp_id}, _session, socket) do
    case load_employee(emp_id, socket) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, gettext("Please select a valid employee first."))
         |> push_navigate(to: ~p"/companies/#{socket.assigns.current_company.id}/take_photo")}

      emp ->
        {:ok,
         socket
         |> assign(page_title: "Take Photo")
         |> assign(full_screen_app?: true)
         |> assign(emp: emp)}
    end
  end

  defp load_employee(emp_id, socket) do
    FullCircle.HR.get_employee!(
      emp_id,
      socket.assigns.current_company,
      socket.assigns.current_user
    )
  rescue
    _ -> nil
  end

  @impl true
  def handle_event("save_photos_batch", %{"photos" => photos}, socket) do
    require Logger

    results =
      Enum.map(photos, fn %{"discriptor" => discriptor, "photo" => photo} ->
        StdInterface.create(
          EmployeePhoto,
          "employee_photo",
          %{
            "photo_descriptor" => discriptor,
            "photo_data" => photo,
            "photo_type" => "png",
            "flag" => "source",
            "employee_id" => socket.assigns.emp.id
          },
          socket.assigns.current_company,
          socket.assigns.current_user
        )
      end)

    {oks, errs} = Enum.split_with(results, &match?({:ok, _}, &1))

    Enum.each(oks, fn {:ok, saved} ->
      PubSub.broadcast(
        FullCircle.PubSub,
        "#{socket.assigns.current_company.id}_refresh_face_id_data",
        {:new_photo, saved}
      )
    end)

    if errs != [] do
      Logger.warning(
        "save_photos_batch: #{length(oks)}/#{length(photos)} saved. Failures: #{inspect(errs, limit: :infinity, printable_limit: 500)}"
      )
    end

    # Cap per-employee photo count and broadcast removals so the face_id cache stays in sync.
    pruned =
      FullCircle.HR.prune_employee_photos(
        socket.assigns.emp.id,
        socket.assigns.current_company.id,
        30
      )

    Enum.each(pruned, fn id ->
      PubSub.broadcast(
        FullCircle.PubSub,
        "#{socket.assigns.current_company.id}_refresh_face_id_data",
        {:delete_photo, id}
      )
    end)

    {:noreply,
     socket
     |> push_navigate(
       to: ~p"/companies/#{socket.assigns.current_company.id}/take_photo/#{socket.assigns.emp.id}/photos"
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="employee_info" class="text-center">
      <div class="text-2xl font-bold mt-2 mb-1">{@emp.name}</div>
      <input type="hidden" id="employee_id" value={@emp.id} />

      <div id="take-photo" phx-hook="takePhoto" phx-update="ignore">
        <canvas id="canvas" class="mx-auto mb-1 w-11/12"></canvas>
        <video id="video" playsinline style="display: none" class="mb-1"></video>
        <div class="text-center mb-1">
          <label for="videoSelect">Camera</label>
          <select id="videoSelect" class="rounded h-8 py-1 pr-8" />
        </div>
        <div id="zoom" class="text-center">
          <label for="zoomSelect">Zoom</label>
          <select id="zoomSelect" class="rounded h-8 py-1 pr-8 mb-1" />
        </div>
        <div id="autoEnrollBtn" class="button blue w-1/2 mx-auto mt-1">
          Auto Enroll (30s)
        </div>
        <div id="enrollPrompt" class="mt-2 text-center text-2xl font-bold text-blue-700" style="display: none;"></div>
        <div id="enrollStatus" class="mt-1 text-center text-sm text-gray-700" style="display: none;"></div>
        <div id="log" class="mt-1 text-center"></div>
        <audio id="shutter-sound" src="/sounds/beep.mp3" type="audio/mpeg" preload="auto"></audio>
      </div>
      <div class="text-center my-4 flex justify-center gap-2">
        <.link
          navigate={~p"/companies/#{@current_company.id}/take_photo/#{@emp.id}/photos"}
          class="blue button"
        >
          {gettext("View Photos")}
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/take_photo"} class="orange button">
          {gettext("Change Employee")}
        </.link>
      </div>
    </div>
    """
  end
end
