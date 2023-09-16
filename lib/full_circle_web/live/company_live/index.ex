defmodule FullCircleWeb.CompanyLiveIndex do
  use FullCircleWeb, :live_view
  alias FullCircle.Sys

  @impl true
  def render(assigns) do
    ~H"""
    <p class="w-full text-3xl text-center font-medium"><%= @page_title %></p>
    <div id="companies_list" class="max-w-2xl mx-auto">
      <%= for c <- @companies do %>
        <div
          id={"company-#{c.company_id}"}
          class={"#{shake(c.updated_at, 2)} border-1 bg-green-200 p-3 m-2 rounded-2xl border-2 border-green-500 text-center"}
        >
          <%= if FullCircle.Authorization.can?(@current_user, :update_company, c) do %>
            <.link
              navigate={~p"/edit_company/#{c.company_id}"}
              class="text-blue-800 text-3xl font-bold"
            >
              <%= c.name %>
            </.link>
          <% else %>
            <div class="text-3xl font-bold">
              <%= c.name %>
            </div>
          <% end %>
          <div class="text-xl"><%= c.reg_no %></div>
          <div class="text-xl">
            <%= [
              c.address1,
              c.address2,
              c.city,
              c.zipcode,
              c.state,
              c.country,
              c.tel,
              c.fax,
              c.email
            ]
            |> Enum.reject(fn x -> is_nil(x) end)
            |> Enum.join(", ") %>
          </div>
          <div class="text-amber-700 font-semibold mb-2 text-xl">
            <%= gettext("Your are ") %><span class="text-red-500"><%= c.role %></span><%= gettext(
              " in this farm"
            ) %>
          </div>

          <%= if Util.attempt(assigns[:current_company], :id) != c.company_id do %>
            <.link
              class="set-active blue button mx-2"
              phx-value-id={c.company_id}
              navigate={~p"/companies/#{c.company_id}/dashboard"}
            >
              <%= gettext("Set Active") %>
            </.link>
          <% else %>
            <span class="text-xl px-2 py-1 bg-cyan-300 mx-2">
              <%= gettext("Is Active Company") %>
            </span>
          <% end %>

          <%= if !c.default_company do %>
            <.link
              class="set-default blue button mx-2"
              phx-value-id={c.company_id}
              phx-click="set_default"
            >
              <%= gettext("Set Default") %>
            </.link>
          <% else %>
            <span class="text-xl px-2 py-1 bg-cyan-300 mx-2">
              <%= gettext("Is Default Company") %>
            </span>
          <% end %>
        </div>
      <% end %>
    </div>
    <div class="text-center">
      <.link
        navigate={~p"/companies/new"}
        class="border-2 border-amber-500 rounded-md text-center text-2xl px-2 py-1 bg-amber-200"
      >
        <%= gettext("Create a New Company") %>
      </.link>
    </div>
    """
  end

  @impl true
  def mount(_params, session, socket) do
    companies = Sys.list_companies(socket.assigns.current_user)

    socket =
      socket
      |> assign(:page_title, gettext("Company Listing"))
      |> assign(:current_company, session["current_company"])
      |> assign(:current_role, session["current_role"])

    {:ok,
     socket
     |> assign(:companies, companies)}
  end

  @impl true
  def handle_event("set_default", %{"id" => company_id}, socket) do
    Sys.set_default_company(socket.assigns.current_user.id, company_id)

    {:noreply, socket |> assign(:companies, Sys.list_companies(socket.assigns.current_user))}
  end
end
