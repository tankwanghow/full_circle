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
    <div
      id={@id}
      class={"#{@ex_class} cursor-pointer hover:bg-gray-400 accounts text-center mb-1 bg-gray-200 border-gray-500 border-2 rounded p-2"}
      phx-value-contact-id={@contact.id}
      phx-click={:edit_contact}
    >
      <p class="text-xl font-bold"><%= @contact.name %></p>
      <p class="font-light"><%= @contact.address1 %>, <%= @contact.address2 %><br />
        <%= @contact.city %> <%= @contact.zipcode %><br />
        <%= @contact.state %> <%= @contact.country %></p>
      <p><%= @contact.contact_info %></p>
      <%= @contact.descriptions %>
      <%= to_fc_time_format(@contact.updated_at) %>
    </div>
    """
  end
end
