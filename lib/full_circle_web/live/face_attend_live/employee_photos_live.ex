defmodule FullCircleWeb.EmployeePhotosLive do
  use FullCircleWeb, :live_view

  alias Phoenix.PubSub

  @impl true
  def mount(%{"emp_id" => emp_id}, _session, socket) do
    emp =
      FullCircle.HR.get_employee!(
        emp_id,
        socket.assigns.current_company,
        socket.assigns.current_user
      )

    {:ok,
     socket
     |> assign(page_title: "Employee Photos")
     |> assign(full_screen_app?: true)
     |> assign(emp: emp)
     |> assign(photos: FullCircle.HR.get_employee_photos(emp.id, socket.assigns.current_company.id))}
  end

  @impl true
  def handle_event("delete_photo", %{"id" => id}, socket) do
    FullCircle.HR.delete_employee_photo(id)

    PubSub.broadcast(
      FullCircle.PubSub,
      "#{socket.assigns.current_company.id}_refresh_face_id_data",
      {:delete_photo, id}
    )

    {:noreply,
     socket
     |> assign(
       photos: FullCircle.HR.get_employee_photos(socket.assigns.emp.id, socket.assigns.current_company.id)
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="text-center">
      <div class="text-2xl font-bold mt-2">{@emp.name}</div>
      <div class="text-sm text-gray-600 mb-3">
        {gettext("Pictures Taken")}: {length(@photos)}
      </div>

      <div id="photos" class="mx-auto flex max-w-3xl flex-wrap justify-center gap-2 px-2">
        <%= for obj <- @photos do %>
          <div class="px-1 pt-1 w-32 text-center border-2 rounded">
            <img src={obj.photo_data} class="w-full" />
            <div phx-click={:delete_photo} phx-value-id={obj.id} tabindex="-1" class="cursor-pointer">
              <.icon name="hero-trash-solid" class="text-red-500 h-5 w-5" />
            </div>
          </div>
        <% end %>
      </div>

      <div class="text-center my-6 flex justify-center gap-2">
        <.link navigate={~p"/companies/#{@current_company.id}/take_photo"} class="blue button">
          {gettext("Back to Take Photo")}
        </.link>
      </div>
    </div>
    """
  end
end
