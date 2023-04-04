defmodule FullCircleWeb.DashboardLive do
  use FullCircleWeb, :live_view

  @impl true
  def render(assigns) do
    ~H"""
    <p class="w-full text-3xl text-center font-medium"><%= @page_title %></p>
    <div class="max-w-3xl mx-auto">
      <div class="flex flex-wrap shrink grow justify-center gap-2">
        <.link navigate={~p"/companies/#{@current_company.id}/accounts"} class="nav-btn">
          <%= gettext("Accounts") %>
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/contacts"} class="nav-btn">
          <%= gettext("Contacts") %>
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/tax_codes"} class="nav-btn">
          <%= gettext("TaxCodes") %>
        </.link>
      </div>
    </div>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(page_title: gettext("Dashboard"))}
  end
end
