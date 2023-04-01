defmodule FullCircleWeb.ContactLive.ContactIndexComponent do
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
    <div id={@id} class={"#{@ex_class} contacts text-center grid grid-cols-12 gap-1 mb-1"}>
      <div class="col-span-4 rounded bg-gray-50 border-gray-400 border p-2 ">
        <.link
          id={"edit_contact_#{@contact.id}"}
          class="text-blue-600"
          phx-value-contact-id={@contact.id}
          phx-click={:edit_contact}
        >
          <%= @contact.name %>
        </.link>
      </div>
      <div class="col-span-4 rounded bg-gray-50 border-gray-400 border p-2">
        <p><%= @contact.address1 %>,
        <%= @contact.address2 %><br/>
        <%= @contact.city %> <%= @contact.zipcode %><br/>
        <%= @contact.state %> <%= @contact.country %></p>
        <span class="font-light"><%= @contact.contact_info %></span>
      </div>
      <div class="col-span-4 rounded bg-gray-50 border-gray-400 border p-2">
        <%= @contact.descriptions %>
      </div>
    </div>
    """
  end
end
