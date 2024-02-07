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
      class={"#{@ex_class} p-1 text-center bg-gray-200 border-gray-500 hover:bg-gray-300 border-b"}
    >
      <.link
        :if={!FullCircle.Accounting.is_default_account?(@obj)}
        class="hover:font-bold text-blue-600"
        navigate={~p"/companies/#{@current_company.id}/contacts/#{@obj.id}/edit"}
      >
        <%= @obj.name %>
      </.link>
      <div>
        <p><%= @obj.address1 %>, <%= @obj.address2 %>
          <%= @obj.city %> <%= @obj.zipcode %>, <%= @obj.state %> <%= @obj.country %></p>
        <p><%= @obj.contact_info %></p>
      </div>
      <p class="text-green-800"><%= @obj.descriptions %></p>
    </div>
    """
  end
end
