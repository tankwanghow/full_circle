defmodule FullCircleWeb.SelectEmployeeLive do
  use FullCircleWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Select Employee")
     |> assign(full_screen_app?: true)
     |> assign(emp: nil)
     |> assign(emp_name: nil)
     |> assign(error: nil)}
  end

  @impl true
  def handle_event("find_employee", %{"value" => name}, socket) do
    name = String.trim(name || "")

    emp =
      if name == "",
        do: nil,
        else:
          FullCircle.HR.get_employee_by_name(
            name,
            socket.assigns.current_company,
            socket.assigns.current_user
          )

    socket =
      cond do
        emp ->
          socket
          |> assign(emp: emp)
          |> assign(emp_name: emp.name)
          |> assign(error: nil)

        name == "" ->
          socket |> assign(emp: nil) |> assign(emp_name: nil) |> assign(error: nil)

        true ->
          socket
          |> assign(emp: nil)
          |> assign(emp_name: name)
          |> assign(error: gettext("Employee not found"))
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("continue", _, %{assigns: %{emp: %{id: emp_id}}} = socket) do
    {:noreply,
     push_navigate(socket,
       to: ~p"/companies/#{socket.assigns.current_company.id}/take_photo/#{emp_id}"
     )}
  end

  def handle_event("continue", _, socket),
    do: {:noreply, assign(socket, error: gettext("Please select a valid employee first"))}

  @impl true
  def render(assigns) do
    ~H"""
    <div id="employee_info" class="text-center max-w-md mx-auto mt-10 px-4">
      <h1 class="text-2xl font-bold mb-4">{gettext("Select Employee to Take Photo")}</h1>

      <input
        type="search"
        id="employee_name"
        phx-hook="tributeAutoComplete"
        phx-blur="find_employee"
        class="rounded h-10 p-1 border w-full text-center mb-2"
        placeholder={gettext("Employee Name...")}
        autocomplete="off"
        url={"/list/companies/#{@current_company.id}/#{@current_user.id}/autocomplete?schema=employee&name="}
        value={@emp_name}
      />

      <%= if @emp do %>
        <div class="text-green-700 font-semibold mb-2">
          ✓ {@emp.name}
        </div>
      <% end %>

      <%= if @error do %>
        <div class="text-red-600 mb-2">{@error}</div>
      <% end %>

      <div class="flex justify-center gap-2 mt-4">
        <button
          phx-click="continue"
          class={["button", if(@emp, do: "green", else: "gray")]}
          disabled={is_nil(@emp)}
        >
          {gettext("Continue")}
        </button>
        <.link navigate={~p"/companies/#{@current_company.id}/dashboard"} class="red button">
          {gettext("Dashboard")}
        </.link>
      </div>
    </div>
    """
  end
end
