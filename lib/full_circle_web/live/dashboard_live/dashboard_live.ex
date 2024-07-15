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
      <div :if={@current_role == "admin"} class="mb-4 gap-1 flex flex-wrap justify-center">
        <.link navigate={~p"/companies/#{@current_company.id}/seeds"} class="button red">
          <%= gettext("Seeding") %>
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/users"} class="button red">
          <%= gettext("Users") %>
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/rouge_users"} class="button red">
          <%= gettext("Rouge Users") %>
        </.link>
      </div>
      <div class="font-medium text-xl">Accounting</div>
      <div class="mb-4 gap-1 flex flex-wrap justify-center">
        <.link navigate={~p"/companies/#{@current_company.id}/accounts"} class="button blue">
          <%= gettext("Accounts") %>
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/contacts"} class="button blue">
          <%= gettext("Contacts") %>
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/fixed_assets"} class="button blue">
          <%= gettext("Fixed Assets") %>
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/Receipt"} class="button blue">
          <%= gettext("Receipts") %>
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/Payment"} class="button blue">
          <%= gettext("Payments") %>
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/Deposit"} class="button blue">
          <%= gettext("Deposits") %>
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/CreditNote"} class="button blue">
          <%= gettext("Credit Notes") %>
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/DebitNote"} class="button blue">
          <%= gettext("Debit Notes") %>
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/ReturnCheque"} class="button blue">
          <%= gettext("Return Cheques") %>
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/Journal"} class="button blue">
          <%= gettext("Journal Entries") %>
        </.link>
      </div>

      <div class="font-medium text-xl">Sales Purchase</div>
      <div class="mb-4 gap-1 flex flex-wrap justify-center">
        <.link navigate={~p"/companies/#{@current_company.id}/goods"} class="button teal">
          <%= gettext("Goods") %>
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/tax_codes"} class="button teal">
          <%= gettext("TaxCodes") %>
        </.link>
        <!--  <.link navigate={~p"/companies/#{@current_company.id}/Order"} class="button teal">
          <%= gettext("Order") %>
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/Load"} class="button teal">
          <%= gettext("Load") %>
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/Delivery"} class="button teal">
          <%= gettext("Delivery") %>
        </.link> -->
        <.link navigate={~p"/companies/#{@current_company.id}/Invoice"} class="button teal">
          <%= gettext("Invoices") %>
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/PurInvoice"} class="button teal">
          <%= gettext("Purchase Invoices") %>
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/good_sales"} class="button teal">
          <%= gettext("Good Sales") %>
        </.link>
      </div>

      <div class="font-medium text-xl">Payroll</div>
      <div class="mb-4 gap-1 flex flex-wrap justify-center">
        <.link navigate={~p"/companies/#{@current_company.id}/employees"} class="button orange">
          <%= gettext("Employees") %>
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/holidays"} class="button orange">
          <%= gettext("Holiday") %>
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/salary_types"} class="button orange">
          <%= gettext("Salary Types") %>
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/Advance"} class="button orange">
          <%= gettext("Advances") %>
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/SalaryNote"} class="button orange">
          <%= gettext("Salary Notes") %>
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/recurrings"} class="button orange">
          <%= gettext("Recurrings") %>
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/TimeAttend"} class="button orange">
          <%= gettext("Punching RAW Listing") %>
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/PunchIndex"} class="button orange">
          <%= gettext("Punch IO index") %>
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/PunchCard"} class="button orange">
          <%= gettext("Punch Card") %>
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/PayRun"} class="button orange">
          <%= gettext("Pay Run") %>
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/epfsocsoeis"} class="button orange">
          <%= gettext("EPF/SOCSO/EIS") %>
        </.link>
      </div>

      <div class="font-medium text-xl">Operations</div>
      <div class="mb-4 gap-1 flex flex-wrap justify-center">
        <.link navigate={~p"/companies/#{@current_company.id}/Weighing"} class="button gray">
          <%= gettext("Weighings") %>
        </.link>
        <.link
          navigate={~p"/companies/#{@current_company.id}/weighed_goods_report"}
          class="button gray"
        >
          <%= gettext("Weight Goods Report") %>
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/houses"} class="button gray">
          <%= gettext("House") %>
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/flocks"} class="button gray">
          <%= gettext("Flock") %>
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/harvests"} class="button gray">
          <%= gettext("Harvest") %>
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/harvest_report"} class="button gray">
          <%= gettext("Harvest Report") %>
        </.link>
        <.link
          navigate={~p"/companies/#{@current_company.id}/harvest_wage_report"}
          class="button gray"
        >
          <%= gettext("Harvest Wages Report") %>
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/house_feed"} class="button gray">
          <%= gettext("House Feed") %>
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/upload_files"} class="button gray">
          <%= gettext("Files") %>
        </.link>
      </div>

      <div class="font-medium text-xl">Accounting Reports</div>
      <div class="mb-4 gap-1 flex flex-wrap justify-center">
        <.link
          navigate={~p"/companies/#{@current_company.id}/account_transactions"}
          class="button red"
        >
          <%= gettext("Account Transactions") %>
        </.link>
        <.link
          navigate={~p"/companies/#{@current_company.id}/contact_transactions"}
          class="button red"
        >
          <%= gettext("Contact Transactions") %>
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/debtor_statement"} class="button red">
          <%= gettext("Contact Statement") %>
        </.link>
        <.link
          navigate={~p"/companies/#{@current_company.id}/transport_commission"}
          class="button red"
        >
          <%= gettext("Driver Commission") %>
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/fixed_assets_report"} class="button red">
          <%= gettext("Fixed Assets") %>
        </.link>
        <.link
          navigate={~p"/companies/#{@current_company.id}/post_dated_cheque_listing"}
          class="button red"
        >
          <%= gettext("Post Dated Cheques") %>
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/tbplbs"} class="button red">
          <%= gettext("TB/PL/BS") %>
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/aging"} class="button red">
          <%= gettext("Agings") %>
        </.link>
        <.link
          :if={@current_role == "admin"}
          navigate={~p"/companies/#{@current_company.id}/queries"}
          class="button red"
        >
          <%= gettext("Queries") %>
        </.link>
      </div>
    </div>
    <div
      :if={FullCircle.Authorization.can?(@current_user, :create_time_attendence, @current_company)}
      class="mx-auto text-center"
    >
      <div class="mt-20 text-2xl font-bold">
        <.link navigate={~p"/companies/#{@current_company.id}/PunchCamera"} class="blue button">
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
