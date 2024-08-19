defmodule FullCircleWeb.TakePhotoLive do
  use FullCircleWeb, :live_view

  alias FullCircle.HR.EmployeePhoto
  alias FullCircle.StdInterface

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(full_screen_app?: true)
     |> assign(emp_id: nil)
     |> assign(emp_name: nil)
     |> assign(photos: [])}
  end

  @impl true
  def handle_event(
        "save-photo",
        %{"descriptor" => descriptor, "photo-data" => photo_data},
        socket
      ) do
    attrs = %{
      live_action: :new,
      employee_id: "2f123943-f345-41af-ba77-ae4366c0e3d4",
      flag: "source",
      photo_data: photo_data,
      photo_descriptor:
        descriptor |> String.split(",") |> Enum.map(fn x -> String.to_float(x) end),
      photo_type: "png",
      company_id: socket.assigns.current_company.id
    }

    StdInterface.create(
      EmployeePhoto,
      "employee_photo",
      attrs,
      socket.assigns.current_company,
      socket.assigns.current_user
    )

    {:noreply, socket}
  end

  @impl true
  def handle_event("find_employee_id", %{"value" => name}, socket) do
    emp =
      FullCircle.HR.get_employee_by_name(
        name,
        socket.assigns.current_company,
        socket.assigns.current_user
      )

    socket =
      if emp do
        socket
        |> assign(emp_id: emp.id)
        |> assign(emp_name: emp.name)
        |> assign(
          photos: FullCircle.HR.get_employee_photos(emp.id, socket.assigns.current_company.id)
        )
      else
        socket
        |> assign(emp_id: nil)
        |> assign(emp_name: name)
        |> assign(photos: [])
      end

    {:noreply, socket |> push_event("retry_from_lv", %{})}
  end

  @impl true
  def handle_event("got_photo", %{"discriptor" => discriptor, "photo" => photo}, socket) do
    {:noreply, socket |> assign(discriptor: discriptor) |> assign(photo: photo)}
  end

  @impl true
  def handle_event("delete_photo", %{"id" => id}, socket) do
    FullCircle.HR.delete_employee_photo(id)

    {:noreply,
     socket
     |> assign(
       photos:
         FullCircle.HR.get_employee_photos(
           socket.assigns.emp_id,
           socket.assigns.current_company.id
         )
     )}
  end

  @impl true
  def handle_event("save_photo", _, socket) do
    StdInterface.create(
      EmployeePhoto,
      "employee_photo",
      %{
        "photo_descriptor" => socket.assigns.discriptor,
        "photo_data" => socket.assigns.photo,
        "photo_type" => "png",
        "flag" => "source",
        "employee_id" => socket.assigns.emp_id
      },
      socket.assigns.current_company,
      socket.assigns.current_user
    )

    {:noreply,
     socket
     |> assign(
       photos:
         FullCircle.HR.get_employee_photos(
           socket.assigns.emp_id,
           socket.assigns.current_company.id
         )
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="employee_info" class="text-center">
      <input
        type="search"
        id="employee_name"
        phx-hook="tributeAutoComplete"
        phx-blur="find_employee_id"
        class="rounded h-8 p-1 border w-80 text-center mb-1"
        placeholder="Employee Name..."
        autocomplete="off"
        url={"/list/companies/#{@current_company.id}/#{@current_user.id}/autocomplete?schema=employee&name="}
        value={@emp_name}
      />
      <input
        readonly
        id="employee_id"
        class="rounded h-8 p-1 border w-80 text-center mb-1"
        placeholder="Employee Id Not Found..."
        value={@emp_id}
        tabindex="-1"
      />
      <div id="photos" class="mx-auto flex w-80 flex-wrap">
        <%= for obj <- @photos do %>
          <div class="px-1 pt-1 w-1/5 h-1/5 text-center border-2 rounded">
            <img src={obj.photo_data} />
            <div phx-click={:delete_photo} phx-value-id={obj.id} tabindex="-1">
              <.icon name="hero-trash-solid" class="text-red-500 h-4 w-4" />
            </div>
          </div>
        <% end %>
      </div>

      <div id="take-photo" phx-hook="takePhotoHuman" phx-update="ignore">
        <canvas id="canvas" class="mx-auto mb-1"></canvas>
        <video id="video" playsinline style="display: none" class="mb-1"></video>
        <div class="text-center mb-1">
          <label for="videoSelect">Camera</label>
          <select id="videoSelect" class="rounded h-8 py-1 pr-8" />
        </div>
        <div id="zoom" class="text-center">
          <label for="zoomSelect">Zoom</label>
          <select id="zoomSelect" class="rounded h-8 py-1 pr-8 mb-1" />
        </div>
        <div id="retry" class="button blue w-1/2 mx-auto" style="display: none">
          Scan Face
        </div>
        <div id="snapBtn" class="button green w-1/2 mx-auto">
          Take Photo
        </div>
        <div id="saveBtn" class="button green w-1/2 mx-auto" style="display: none;">
          Save
        </div>
        <div id="log" class="mt-1 text-center"></div>
      </div>
      <div class="text-center mt-4">
        <.link navigate={~p"/companies/#{@current_company.id}/dashboard"} class="red button">
          <%= gettext("Back") %>
        </.link>
      </div>
    </div>
    """
  end
end
