defmodule FullCircleWeb.FaceIdLive do
  use FullCircleWeb, :live_view

  # alias FullCircle.HR.EmployeePhoto
  # alias FullCircle.StdInterface
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
  def handle_info({:new_photo, data}, socket) do
    IO.inspect(data)
    {:noreply, socket}
  end

  @impl true
  def handle_info({:delete_photo, data}, socket) do
    IO.inspect(data)
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="employee_info" class="text-center">
      <div id="photos" class="mx-auto flex w-80 flex-wrap">
        <%= for obj <- @photos do %>
          <div class="px-1 pt-1 w-1/5 h-1/5 text-center border-2 rounded">
            <img src={obj.photo_data} />
          </div>
        <% end %>
      </div>

      <div id="faceID" phx-hook="FaceID" phx-update="ignore">
        <canvas id="canvas" class="mx-auto mb-1 w-11/12"></canvas>
        <video id="video" playsinline style="display: none" class="mb-1"></video>
        <div class="text-center">
          <label for="videoSelect">Camera</label>
          <select id="videoSelect" class="rounded h-8 py-1 pr-8" />
        </div>
        <div id="in_out" class="flex mt-3 gap-1 p-2 text-3xl" style="display: none;">
          <button id="outBtn" class="w-1/2 h-20 red button font-bold">
            <%= gettext("OUT") %>
          </button>
          <button id="inBtn" class="w-1/2 h-20 green button font-bold">
            <%= gettext("IN") %>
          </button>
        </div>
        <div id="scanResultName" class="mt-1 font-bold text-xl text-blue-700"></div>
        <div id="scanResultPhotos" class="flex p-1 gap-1 mx-auto w-11/12"></div>
        <div
          id="compareList"
          style="display: none;"
          class="flex flex-wrap p-1 gap-1 mx-auto border border-red-400 text-xs w-11/12"
        >
        </div>
        <div id="log" class="mt-1 text-center"></div>
      </div>
      <div class="text-center my-4">
        <.link navigate={~p"/companies/#{@current_company.id}/dashboard"} class="orange button">
          <%= gettext("Back") %>
        </.link>
      </div>
    </div>
    """
  end
end
