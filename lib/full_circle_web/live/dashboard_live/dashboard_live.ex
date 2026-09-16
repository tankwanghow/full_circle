defmodule FullCircleWeb.DashboardLive do
  use FullCircleWeb, :live_view

  @impl true
  def render(assigns) do
    ~H"""
    <p class="w-full text-3xl text-center font-medium">{@page_title}</p>
    <div class="mx-auto w-6/12 text-center">
      <div :if={@current_role == "admin"} class="font-medium text-xl">
        Administrator Functions
      </div>
      <div :if={@current_role == "admin"} class="mb-4 gap-1 flex flex-wrap justify-center">
        <.link navigate={~p"/companies/#{@current_company.id}/seeds"} class="button red">
          {gettext("Seeding")}
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/users"} class="button red">
          {gettext("Users")}
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/rouge_users"} class="button red">
          {gettext("Rouge Users")}
        </.link>
        <.link
          :if={@current_role == "admin"}
          navigate={~p"/companies/#{@current_company.id}/statutory_calcs"}
          class="button red"
        >
          {gettext("Statutory Calcs")}
        </.link>
        <.link
          :if={@current_role == "admin"}
          navigate={~p"/companies/#{@current_company.id}/egg_price_history"}
          class="button red"
        >
          {gettext("Egg Price History")}
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/upload_files"} class="button red">
          {gettext("Files")}
        </.link>
      </div>

      <div class="font-medium text-xl">Daily</div>
      <div class="mb-4 gap-1 flex flex-wrap justify-center">
        <.link navigate={~p"/companies/#{@current_company.id}/Receipt"} class="button blue">
          {gettext("Receipts")}
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/Payment"} class="button blue">
          {gettext("Payments")}
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/Deposit"} class="button blue">
          {gettext("Deposits")}
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/Invoice"} class="button blue">
          {gettext("Invoices")}
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/PurInvoice"} class="button blue">
          {gettext("Purchase Invoices")}
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/Weighing"} class="button blue">
          {gettext("Weighings")}
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/PunchCard"} class="button blue">
          {gettext("Punch Card")}
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/Journal"} class="button blue">
          {gettext("Journal Entries")}
        </.link>
      </div>

      <div class="font-medium text-xl">Cash &amp; Bank</div>
      <div class="mb-4 gap-1 flex flex-wrap justify-center">
        <.link navigate={~p"/companies/#{@current_company.id}/ReturnCheque"} class="button blue">
          {gettext("Return Cheques")}
        </.link>
        <.link
          :if={
            FullCircle.Authorization.can?(@current_user, :view_bank_reconciliation, @current_company)
          }
          navigate={~p"/companies/#{@current_company.id}/bank_reconciliation"}
          class="button blue"
        >
          {gettext("Bank Reconciliation")}
        </.link>
        <.link
          navigate={~p"/companies/#{@current_company.id}/post_dated_cheque_listing"}
          class="button blue"
        >
          {gettext("Post Dated Cheques")}
        </.link>
      </div>

      <div class="font-medium text-xl">Sales &amp; Purchase</div>
      <div class="mb-4 gap-1 flex flex-wrap justify-center">
        <.link navigate={~p"/companies/#{@current_company.id}/CreditNote"} class="button teal">
          {gettext("Credit Notes")}
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/DebitNote"} class="button teal">
          {gettext("Debit Notes")}
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/good_snp"} class="button teal">
          {gettext("Goods Sales & Purchases")}
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/trading/desk"} class="button teal">
          {gettext("Trading Desk")}
        </.link>
        <.link
          navigate={~p"/companies/#{@current_company.id}/trading/settlement"}
          class="button teal"
        >
          {gettext("Trading Settlement")}
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/trading/locations"} class="button teal">
          {gettext("Locations")}
        </.link>
      </div>

      <div class="font-medium text-xl">E-Invoice</div>
      <div class="mb-4 gap-1 flex flex-wrap justify-center">
        <.link navigate={~p"/companies/#{@current_company.id}/e_invoices"} class="button teal">
          {gettext("E-Invoices")}
        </.link>
        <.link
          navigate={~p"/companies/#{@current_company.id}/e_invoice_queue"}
          class="button teal"
        >
          {gettext("E-Invoice Queue")}
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/e_inv_meta"} class="button teal">
          {gettext("E-Invoice Meta Data")}
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/tax_codes"} class="button teal">
          {gettext("TaxCodes")}
        </.link>
      </div>

      <div class="font-medium text-xl">Masters</div>
      <div class="mb-4 gap-1 flex flex-wrap justify-center">
        <.link navigate={~p"/companies/#{@current_company.id}/accounts"} class="button blue">
          {gettext("Accounts")}
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/contacts"} class="button blue">
          {gettext("Contacts")}
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/fixed_assets"} class="button blue">
          {gettext("Fixed Assets")}
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/goods"} class="button blue">
          {gettext("Goods")}
        </.link>
      </div>

      <div class="font-medium text-xl">Payroll — People</div>
      <div class="mb-4 gap-1 flex flex-wrap justify-center">
        <.link navigate={~p"/companies/#{@current_company.id}/employees"} class="button orange">
          {gettext("Employees")}
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/Advance"} class="button orange">
          {gettext("Advances")}
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/SalaryNote"} class="button orange">
          {gettext("Salary Notes")}
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/recurrings"} class="button orange">
          {gettext("Recurrings")}
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/salary_types"} class="button orange">
          {gettext("Salary Types")}
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/holidays"} class="button orange">
          {gettext("Holiday")}
        </.link>
      </div>

      <div class="font-medium text-xl">Payroll — Attendance</div>
      <div class="mb-4 gap-1 flex flex-wrap justify-center">
        <.link navigate={~p"/companies/#{@current_company.id}/PunchIndex"} class="button orange">
          {gettext("Punch IO index")}
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/TimeAttend"} class="button orange">
          {gettext("Punching RAW Listing")}
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/import_attend"} class="button orange">
          {gettext("Import Attendence File")}
        </.link>
        <.link
          :if={FullCircle.Authorization.can?(@current_user, :manage_punch_device, @current_company)}
          navigate={~p"/companies/#{@current_company.id}/punch_devices"}
          class="button orange"
        >
          {gettext("Punch Devices")}
        </.link>
        <.link
          :if={FullCircle.Authorization.can?(@current_user, :update_work_shift, @current_company)}
          navigate={~p"/companies/#{@current_company.id}/work_shifts"}
          class="button orange"
        >
          {gettext("Work Shifts")}
        </.link>
        <.link
          :if={
            FullCircle.Authorization.can?(
              @current_user,
              :view_punch_ingest_log,
              @current_company
            )
          }
          navigate={~p"/companies/#{@current_company.id}/punch_ingest_logs"}
          class="button orange"
        >
          {gettext("Punch Ingest Log")}
        </.link>
      </div>

      <div class="font-medium text-xl">Payroll — Run &amp; Statutory</div>
      <div class="mb-4 gap-1 flex flex-wrap justify-center">
        <.link navigate={~p"/companies/#{@current_company.id}/PayRun"} class="button orange">
          {gettext("Pay Run")}
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/epfsocsoeis"} class="button orange">
          {gettext("EPF/SOCSO/EIS")}
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/eaform"} class="button orange">
          {gettext("EA Form")}
        </.link>
      </div>

      <div class="font-medium text-xl">Farm</div>
      <div class="mb-4 gap-1 flex flex-wrap justify-center">
        <.link navigate={~p"/companies/#{@current_company.id}/houses"} class="button gray">
          {gettext("House")}
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/flocks"} class="button gray">
          {gettext("Flock")}
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/harvests"} class="button gray">
          {gettext("Harvest")}
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/house_feed"} class="button gray">
          {gettext("House Feed")}
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/egg_stock"} class="button gray">
          {gettext("Egg Stock")}
        </.link>
        <.link
          navigate={~p"/companies/#{@current_company.id}/weighed_goods_report"}
          class="button gray"
        >
          {gettext("Weight Goods Report")}
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/harvest_report"} class="button gray">
          {gettext("Harvest Report")}
        </.link>
        <.link
          navigate={~p"/companies/#{@current_company.id}/harvest_wage_report"}
          class="button gray"
        >
          {gettext("Harvest Wages Report")}
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/feed_egg_report"} class="button gray">
          {gettext("Feed vs Egg Report")}
        </.link>
      </div>

      <div class="font-medium text-xl">Reports</div>
      <div class="mb-4 gap-1 flex flex-wrap justify-center">
        <.link
          navigate={~p"/companies/#{@current_company.id}/account_transactions"}
          class="button red"
        >
          {gettext("Account Transactions")}
        </.link>
        <.link
          navigate={~p"/companies/#{@current_company.id}/contact_transactions"}
          class="button red"
        >
          {gettext("Contact Transactions")}
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/debtor_statement"} class="button red">
          {gettext("Contact Statement")}
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/aging"} class="button red">
          {gettext("Agings")}
        </.link>
        <.link
          navigate={~p"/companies/#{@current_company.id}/transport_commission"}
          class="button red"
        >
          {gettext("Driver Commission")}
        </.link>
        <.link
          :if={@current_role == "admin"}
          navigate={~p"/companies/#{@current_company.id}/financial_statements"}
          class="button red"
        >
          {gettext("Financial Statements")}
        </.link>
        <.link
          :if={@current_role == "admin"}
          navigate={~p"/companies/#{@current_company.id}/cash_forecast"}
          class="button red"
        >
          {gettext("Cash Forecast")}
        </.link>
        <.link
          :if={@current_role == "admin"}
          navigate={~p"/companies/#{@current_company.id}/profit_loss_forecast"}
          class="button red"
        >
          {gettext("P&L Forecast")}
        </.link>
        <.link
          :if={@current_role == "admin"}
          navigate={~p"/companies/#{@current_company.id}/fixed_assets_report"}
          class="button red"
        >
          {gettext("Fixed Assets")}
        </.link>
        <.link
          :if={@current_role == "admin"}
          navigate={~p"/companies/#{@current_company.id}/queries"}
          class="button red"
        >
          {gettext("Queries")}
        </.link>
      </div>
    </div>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(:back_to_route, "#") |> assign(page_title: gettext("Dashboard"))}
  end

  @impl true
  def handle_params(_, _uri, socket) do
    {:noreply, socket}
  end
end
