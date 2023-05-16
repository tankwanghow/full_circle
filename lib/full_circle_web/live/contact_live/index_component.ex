defmodule FullCircleWeb.ContactLive.IndexComponent do
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
      class={"#{@ex_class} text-center mb-1 bg-gray-200 border-gray-500 border-2 rounded p-2"}
    >
      <span
        class="text-xl font-bold hover:bg-blue-400 cursor-pointer bg-blue-100 border-blue-500 px-2 py-1 rounded-full border"
        phx-value-contact-id={@contact.id}
        phx-click={:edit_contact}
      >
        <%= @contact.name %>
      </span>
      <div class="text-sm mt-2">
        <p><%= @contact.address1 %>, <%= @contact.address2 %></p>
        <p>
          <%= @contact.city %> <%= @contact.zipcode %>, <%= @contact.state %> <%= @contact.country %>
        </p>
        <p><%= @contact.contact_info %></p>
      </div>
      <p class="text-green-800"><%= @contact.descriptions %></p>
      <span class="text-xs font-light"><%= to_fc_time_format(@contact.updated_at) %></span>
      <.live_component
        module={FullCircleWeb.LogLive.Component}
        id={"log_#{@contact.id}"}
        show_log={false}
        entity="contacts"
        entity_id={@contact.id}
      />
    </div>
    """
  end
end
