defmodule FullCircleWeb.EmployeeLive.IndexComponent do
  use FullCircleWeb, :live_component

  @impl true
  def mount(socket) do
    {:ok, socket}
  end

  @impl true
  def update(assigns, socket) do
    {:ok, socket |> assign(assigns)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id={@id}
      class={"#{@ex_class} flex text-center bg-gray-200 border-gray-500 hover:bg-gray-300 border-b p-1"}
    >
      <div class="w-[3%]">
        <input
          :if={@obj.checked and @obj.status == "Active"}
          id={"checkbox_#{@obj.id}"}
          type="checkbox"
          phx-click="check_click"
          phx-value-object-id={@obj.id}
          class="rounded border-gray-400 checked:bg-gray-400"
          checked
        />
        <input
          :if={!@obj.checked and @obj.status == "Active"}
          id={"checkbox_#{@obj.id}"}
          type="checkbox"
          class="rounded border-gray-400 checked:bg-gray-400"
          phx-click="check_click"
          phx-value-object-id={@obj.id}
        />
      </div>

      <div class="w-[41%]">
        <.link
          class="text-blue-600 hover:font-bold"
          tabindex="-1"
          navigate={~p"/companies/#{@current_company}/employees/#{@obj.id}/edit"}
        >
          {@obj.name}
        </.link>
      </div>
      <div class="w-[20%]">
        {@obj.id_no}
      </div>
      <div class="w-[20%]">
        {@obj.nationality}
      </div>
      <div class="w-[10%]">
        {@obj.status}
      </div>
      <div class="w-[6%]">
        <.link
          tabindex="-1"
          navigate={~p"/companies/#{@current_company}/employees/#{@obj.id}/copy"}
          class="text-xs hover:bg-orange-400 bg-orange-200 py-1 px-2 rounded-full border-orange-400 border"
        >
          {gettext("Copy")}
        </.link>
      </div>
    </div>
    """
  end
end
