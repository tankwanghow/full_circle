defmodule FullCircleWeb.DashboardLive do
  use FullCircleWeb, :live_view

  @impl true
  def render(assigns) do
    ~H"""
    <p class="w-full text-3xl text-center font-medium"><%= @page_title %></p>
    <div class="mx-auto w-8/12">
      <div class="flex flex-wrap shrink grow justify-center">
        <.link navigate={~p"/companies/#{@current_company.id}/seeds"} class="nav-btn">
          <%= gettext("Seeding") %>
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/accounts"} class="nav-btn">
          <%= gettext("Accounts") %>
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/fixed_assets"} class="nav-btn">
          <%= gettext("Fixed Assets") %>
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/contacts"} class="nav-btn">
          <%= gettext("Contacts") %>
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/tax_codes"} class="nav-btn">
          <%= gettext("TaxCodes") %>
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/goods"} class="nav-btn">
          <%= gettext("Goods") %>
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/invoices"} class="nav-btn">
          <%= gettext("Invoices") %>
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/pur_invoices"} class="nav-btn">
          <%= gettext("Purchase Invoices") %>
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/account_transactions"} class="nav-btn">
          <%= gettext("Account Transactions") %>
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
