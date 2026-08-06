defmodule FullCircleWeb.DashboardLive do
  use FullCircleWeb, :live_view

  alias FullCircle.Dashboard

  @impl true
  def render(assigns) do
    ~H"""
    <p class="w-full text-3xl text-center font-medium">{@page_title}</p>

    <div
      :if={@current_role != "punch_camera" and @today}
      class="mx-auto w-11/12 max-w-4xl mb-8"
    >
      <div class="rounded-lg border border-gray-300 bg-white dark:bg-gray-800 dark:border-gray-600 shadow-sm p-4">
        <div class="flex flex-wrap items-center justify-between gap-2 mb-3">
          <h2 class="text-xl font-semibold">
            {gettext("Today")}
            <span class="text-base font-normal text-gray-500 ml-2">
              {Calendar.strftime(@today.date, "%d/%m/%Y")}
            </span>
          </h2>
          <p class="text-sm text-gray-500">
            {gettext("Ctrl+K to search · newinv / newdep to create")}
          </p>
        </div>

        <div class="flex flex-wrap gap-2 mb-4">
          <div class="rounded-md bg-emerald-50 dark:bg-emerald-900/30 border border-emerald-200 dark:border-emerald-800 px-3 py-2 min-w-[5rem] text-center">
            <div class="text-2xl font-bold text-emerald-700 dark:text-emerald-300">{@today.total}</div>
            <div class="text-xs text-gray-600 dark:text-gray-400">{gettext("docs today")}</div>
          </div>
          <div
            :for={{type, count} <- Enum.sort(@today.counts)}
            class="rounded-md bg-gray-50 dark:bg-gray-700/50 border border-gray-200 dark:border-gray-600 px-3 py-2 min-w-[5rem] text-center"
          >
            <div class="text-xl font-semibold">{count}</div>
            <div class="text-xs text-gray-600 dark:text-gray-400">{Dashboard.type_label(type)}</div>
          </div>
          <div
            :if={@today.total == 0}
            class="text-sm text-gray-500 self-center px-2"
          >
            {gettext("No finance documents dated today yet.")}
          </div>
        </div>

        <div class="font-medium text-sm text-gray-600 dark:text-gray-300 mb-2">{gettext("Quick open")}</div>
        <div class="flex flex-wrap gap-1 justify-start">
          <.link
            :if={FullCircle.Authorization.can?(@current_user, :create_invoice, @current_company)}
            navigate={~p"/companies/#{@current_company.id}/Invoice/new"}
            class="button teal"
          >
            {gettext("New Invoice")}
          </.link>
          <.link
            :if={FullCircle.Authorization.can?(@current_user, :create_receipt, @current_company)}
            navigate={~p"/companies/#{@current_company.id}/Receipt/new"}
            class="button blue"
          >
            {gettext("New Receipt")}
          </.link>
          <.link
            :if={FullCircle.Authorization.can?(@current_user, :create_payment, @current_company)}
            navigate={~p"/companies/#{@current_company.id}/Payment/new"}
            class="button blue"
          >
            {gettext("New Payment")}
          </.link>
          <.link
            :if={FullCircle.Authorization.can?(@current_user, :create_deposit, @current_company)}
            navigate={~p"/companies/#{@current_company.id}/Deposit/new"}
            class="button blue"
          >
            {gettext("New Deposit")}
          </.link>
          <.link navigate={~p"/companies/#{@current_company.id}/aging"} class="button red">
            {gettext("Aging")}
          </.link>
          <.link
            :if={@current_role == "admin"}
            navigate={~p"/companies/#{@current_company.id}/cash_forecast"}
            class="button red"
          >
            {gettext("Cash Forecast")}
          </.link>
          <.link
            :if={FullCircle.Authorization.can?(@current_user, :view_trading, @current_company)}
            navigate={~p"/companies/#{@current_company.id}/trading/desk"}
            class="button teal"
          >
            {gettext("Trading Desk")}
          </.link>
          <.link navigate={~p"/companies/#{@current_company.id}/egg_stock"} class="button gray">
            {gettext("Egg Stock")}
          </.link>
          <.link
            :if={
              FullCircle.Authorization.can?(
                @current_user,
                :view_bank_reconciliation,
                @current_company
              )
            }
            navigate={~p"/companies/#{@current_company.id}/bank_reconciliation"}
            class="button blue"
          >
            {gettext("Bank Recon")}
          </.link>
        </div>
      </div>
    </div>

    <div :if={@current_role != "punch_camera"} class="mx-auto w-6/12 text-center">
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
      </div>
      <div class="font-medium text-xl">Accounting</div>
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
        <.link navigate={~p"/companies/#{@current_company.id}/Receipt"} class="button blue">
          {gettext("Receipts")}
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/Payment"} class="button blue">
          {gettext("Payments")}
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/Deposit"} class="button blue">
          {gettext("Deposits")}
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/CreditNote"} class="button blue">
          {gettext("Credit Notes")}
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/DebitNote"} class="button blue">
          {gettext("Debit Notes")}
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/ReturnCheque"} class="button blue">
          {gettext("Return Cheques")}
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/Journal"} class="button blue">
          {gettext("Journal Entries")}
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
      </div>

      <div class="font-medium text-xl">Sales Purchase</div>
      <div class="mb-4 gap-1 flex flex-wrap justify-center">
        <.link navigate={~p"/companies/#{@current_company.id}/goods"} class="button teal">
          {gettext("Goods")}
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/tax_codes"} class="button teal">
          {gettext("TaxCodes")}
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/e_inv_meta"} class="button teal">
          {gettext("E-Invoice Meta Data")}
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/e_invoices"} class="button teal">
          {gettext("E-Invoices")}
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/Invoice"} class="button teal">
          {gettext("Invoices")}
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/PurInvoice"} class="button teal">
          {gettext("Purchase Invoices")}
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/good_sales"} class="button teal">
          {gettext("Good Sales")}
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

      <div class="font-medium text-xl">Payroll</div>
      <div class="mb-4 gap-1 flex flex-wrap justify-center">
        <.link navigate={~p"/companies/#{@current_company.id}/employees"} class="button orange">
          {gettext("Employees")}
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/import_attend"} class="blue button">
          {gettext("Import Attendence File")}
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/holidays"} class="button orange">
          {gettext("Holiday")}
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/salary_types"} class="button orange">
          {gettext("Salary Types")}
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
        <.link navigate={~p"/companies/#{@current_company.id}/TimeAttend"} class="button orange">
          {gettext("Punching RAW Listing")}
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/PunchIndex"} class="button orange">
          {gettext("Punch IO index")}
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/PunchCard"} class="button orange">
          {gettext("Punch Card")}
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/PayRun"} class="button orange">
          {gettext("Pay Run")}
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/epfsocsoeis"} class="button orange">
          {gettext("EPF/SOCSO/EIS")}
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/eaform"} class="button orange">
          {gettext("EA Form")}
        </.link>
        <.link
          :if={@current_role == "admin"}
          navigate={~p"/companies/#{@current_company.id}/statutory_calcs"}
          class="button orange"
        >
          {gettext("Statutory Calcs")}
        </.link>
      </div>

      <div class="font-medium text-xl">Operations</div>
      <div class="mb-4 gap-1 flex flex-wrap justify-center">
        <.link navigate={~p"/companies/#{@current_company.id}/Weighing"} class="button gray">
          {gettext("Weighings")}
        </.link>
        <.link
          navigate={~p"/companies/#{@current_company.id}/weighed_goods_report"}
          class="button gray"
        >
          {gettext("Weight Goods Report")}
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/houses"} class="button gray">
          {gettext("House")}
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/flocks"} class="button gray">
          {gettext("Flock")}
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/harvests"} class="button gray">
          {gettext("Harvest")}
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
        <.link navigate={~p"/companies/#{@current_company.id}/house_feed"} class="button gray">
          {gettext("House Feed")}
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/feed_egg_report"} class="button gray">
          {gettext("Feed vs Egg Report")}
        </.link>
        <.link
          :if={@current_role == "admin"}
          navigate={~p"/companies/#{@current_company.id}/egg_price_history"}
          class="button gray"
        >
          {gettext("Egg Price History")}
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/egg_stock"} class="button gray">
          {gettext("Egg Stock")}
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/upload_files"} class="button gray">
          {gettext("Files")}
        </.link>
      </div>

      <div class="font-medium text-xl">Accounting Reports</div>
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
        <.link
          navigate={~p"/companies/#{@current_company.id}/transport_commission"}
          class="button red"
        >
          {gettext("Driver Commission")}
        </.link>
        <.link
          :if={@current_role == "admin"}
          navigate={~p"/companies/#{@current_company.id}/fixed_assets_report"}
          class="button red"
        >
          {gettext("Fixed Assets")}
        </.link>
        <.link
          navigate={~p"/companies/#{@current_company.id}/post_dated_cheque_listing"}
          class="button red"
        >
          {gettext("Post Dated Cheques")}
        </.link>
        <.link
          :if={@current_role == "admin"}
          navigate={~p"/companies/#{@current_company.id}/tbplbs"}
          class="button red"
        >
          {gettext("TB/PL/BS")}
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/aging"} class="button red">
          {gettext("Agings")}
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
          navigate={~p"/companies/#{@current_company.id}/queries"}
          class="button red"
        >
          {gettext("Queries")}
        </.link>
      </div>
    </div>
    <div
      :if={FullCircle.Authorization.can?(@current_user, :create_time_attendence, @current_company)}
      class="mx-auto text-center mb-4"
    >
      <%!-- <div class="mt-10 text-2xl font-bold">
        <.link navigate={~p"/companies/#{@current_company.id}/PunchCamera"} class="blue button">
          {gettext("Start Punch Camera")}
        </.link>
      </div>
      <div class="mt-10 text-2xl font-bold">
        <.link navigate={~p"/companies/#{@current_company.id}/POS"} class="blue button">
          {gettext("POS")}
        </.link>
      </div> --%>
      <div class="font-bold">
        <.link navigate={~p"/companies/#{@current_company.id}/take_photo"} class="blue button">
          {gettext("Take A Photo")}
        </.link>
      </div>
      <div class="mt-5 font-bold">
        <.link navigate={~p"/companies/#{@current_company.id}/face_id"} class="blue button">
          {gettext("Face ID")}
        </.link>
      </div>
    </div>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    today =
      if socket.assigns[:current_company] && socket.assigns[:current_user] &&
           socket.assigns[:current_role] != "punch_camera" do
        Dashboard.today_snapshot(socket.assigns.current_company, socket.assigns.current_user)
      else
        nil
      end

    {:ok,
     socket
     |> assign(:back_to_route, "#")
     |> assign(page_title: gettext("Dashboard"))
     |> assign(:today, today)}
  end

  @impl true
  def handle_params(_, _uri, socket) do
    {:noreply, socket}
  end
end
