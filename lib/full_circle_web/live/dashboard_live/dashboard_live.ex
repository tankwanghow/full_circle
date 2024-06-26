defmodule FullCircleWeb.DashboardLive do
  use FullCircleWeb, :live_view

  @impl true
  def render(assigns) do
    ~H"""
    <p class="w-full text-3xl text-center font-medium"><%= @page_title %></p>
    <div :if={@current_role != "punch_camera"} class="mx-auto w-6/12 text-center">
      <div :if={@current_role == "admin"} class="font-medium text-xl">
        Administrator Functions
      </div>
      <div :if={@current_role == "admin"} class="mb-4 flex flex-wrap justify-center">
        <.link navigate={~p"/companies/#{@current_company.id}/seeds"} class="nav-btn">
          <%= gettext("Seeding") %>
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/users"} class="nav-btn">
          <%= gettext("Users") %>
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/rouge_users"} class="nav-btn">
          <%= gettext("Rouge Users") %>
        </.link>
      </div>
      <div class="font-medium text-xl">Accounting</div>
      <div class="mb-4 flex flex-wrap justify-center">
        <.link navigate={~p"/companies/#{@current_company.id}/accounts"} class="nav-btn">
          <%= gettext("Accounts") %>
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/contacts"} class="nav-btn">
          <%= gettext("Contacts") %>
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/fixed_assets"} class="nav-btn">
          <%= gettext("Fixed Assets") %>
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
        <.link navigate={~p"/companies/#{@current_company.id}/CreditNote"} class="nav-btn">
          <%= gettext("Credit Notes") %>
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/DebitNote"} class="nav-btn">
          <%= gettext("Debit Notes") %>
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/ReturnCheque"} class="nav-btn">
          <%= gettext("Return Cheques") %>
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/Journal"} class="nav-btn">
          <%= gettext("Journal Entries") %>
        </.link>
      </div>

      <div class="font-medium text-xl">Sales Purchase</div>
      <div class="mb-4 flex flex-wrap justify-center">
        <.link navigate={~p"/companies/#{@current_company.id}/goods"} class="nav-btn">
          <%= gettext("Goods") %>
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/tax_codes"} class="nav-btn">
          <%= gettext("TaxCodes") %>
        </.link>
        <!--  <.link navigate={~p"/companies/#{@current_company.id}/Order"} class="nav-btn">
          <%= gettext("Order") %>
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/Load"} class="nav-btn">
          <%= gettext("Load") %>
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/Delivery"} class="nav-btn">
          <%= gettext("Delivery") %>
        </.link> -->
        <.link navigate={~p"/companies/#{@current_company.id}/Invoice"} class="nav-btn">
          <%= gettext("Invoices") %>
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/PurInvoice"} class="nav-btn">
          <%= gettext("Purchase Invoices") %>
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/good_sales"} class="nav-btn">
          <%= gettext("Good Sales") %>
        </.link>
      </div>

      <div class="font-medium text-xl">Payroll</div>
      <div class="mb-4 flex flex-wrap justify-center">
        <.link navigate={~p"/companies/#{@current_company.id}/employees"} class="nav-btn">
          <%= gettext("Employees") %>
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/holidays"} class="nav-btn">
          <%= gettext("Holiday") %>
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
        <.link navigate={~p"/companies/#{@current_company.id}/TimeAttend"} class="nav-btn">
          <%= gettext("Punching RAW Listing") %>
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/PunchIndex"} class="nav-btn">
          <%= gettext("Punch IO index") %>
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/PunchCard"} class="nav-btn">
          <%= gettext("Punch Card") %>
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/PayRun"} class="nav-btn">
          <%= gettext("Pay Run") %>
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/epfsocsoeis"} class="nav-btn">
          <%= gettext("EPF/SOCSO/EIS") %>
        </.link>
      </div>

      <div class="font-medium text-xl">Operations</div>
      <div class="mb-4 flex flex-wrap justify-center">
        <.link navigate={~p"/companies/#{@current_company.id}/Weighing"} class="nav-btn">
          <%= gettext("Weighings") %>
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/weighed_goods_report"} class="nav-btn">
          <%= gettext("Weight Goods Report") %>
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/houses"} class="nav-btn">
          <%= gettext("House") %>
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/flocks"} class="nav-btn">
          <%= gettext("Flock") %>
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/harvests"} class="nav-btn">
          <%= gettext("Harvest") %>
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/harvest_report"} class="nav-btn">
          <%= gettext("Harvest Report") %>
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/harvest_wage_report"} class="nav-btn">
          <%= gettext("Harvest Wages Report") %>
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/house_feed"} class="nav-btn">
          <%= gettext("House Feed") %>
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/upload_files"} class="nav-btn">
          <%= gettext("Files") %>
        </.link>
      </div>

      <div class="font-medium text-xl">Accounting Reports</div>
      <div class="mb-4 flex flex-wrap justify-center">
        <.link navigate={~p"/companies/#{@current_company.id}/account_transactions"} class="nav-btn">
          <%= gettext("Account Transactions") %>
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/contact_transactions"} class="nav-btn">
          <%= gettext("Contact Transactions") %>
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/debtor_statement"} class="nav-btn">
          <%= gettext("Contact Statement") %>
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/transport_commission"} class="nav-btn">
          <%= gettext("Driver Commission") %>
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/fixed_assets_report"} class="nav-btn">
          <%= gettext("Fixed Assets") %>
        </.link>
        <.link
          navigate={~p"/companies/#{@current_company.id}/post_dated_cheque_listing"}
          class="nav-btn"
        >
          <%= gettext("Post Dated Cheques") %>
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/tbplbs"} class="nav-btn">
          <%= gettext("TB/PL/BS") %>
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/aging"} class="nav-btn">
          <%= gettext("Agings") %>
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/queries"} class="nav-btn">
          <%= gettext("Queries") %>
        </.link>
      </div>
    </div>
    <div
      :if={FullCircle.Authorization.can?(@current_user, :create_time_attendence, @current_company)}
      class="mx-auto text-center"
    >
      <div class="mt-20 text-2xl font-bold">
        <.link navigate={~p"/companies/#{@current_company.id}/PunchCamera"} class="orange button">
          <%= gettext("Start Punch Camera") %>
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
