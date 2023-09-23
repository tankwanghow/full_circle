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
        <.link navigate={~p"/companies/#{@current_company.id}/Invoice"} class="nav-btn">
          <%= gettext("Invoices") %>
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/Receipt"} class="nav-btn">
          <%= gettext("Receipts") %>
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/Payment"} class="nav-btn">
          <%= gettext("Payments") %>
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/Deposit"} class="nav-btn">
          <%= gettext("Deposits") %>
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/ReturnCheque"} class="nav-btn">
          <%= gettext("Return Cheques") %>
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/PurInvoice"} class="nav-btn">
          <%= gettext("Purchase Invoices") %>
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/account_transactions"} class="nav-btn">
          <%= gettext("Account Transactions") %>
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/contact_transactions"} class="nav-btn">
          <%= gettext("Contact Transactions") %>
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/Journal"} class="nav-btn">
          <%= gettext("Journal Entries") %>
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/CreditNote"} class="nav-btn">
          <%= gettext("Credit Notes") %>
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/DebitNote"} class="nav-btn">
          <%= gettext("Debit Notes") %>
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/employees"} class="nav-btn">
          <%= gettext("Employees") %>
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/salary_types"} class="nav-btn">
          <%= gettext("Salary Types") %>
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/Advance"} class="nav-btn">
          <%= gettext("Advances") %>
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/SalaryNote"} class="nav-btn">
          <%= gettext("Salary Notes") %>
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/recurrings"} class="nav-btn">
          <%= gettext("Recurrings") %>
        </.link>
      </div>
    </div>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(:back_to_route, "#") |> assign(page_title: gettext("Dashboard"))}
  end
end
