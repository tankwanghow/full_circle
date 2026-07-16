defmodule FullCircleWeb.DashboardLive.Menu do
  @moduledoc """
  Hub cards and section link maps for the company dashboard.
  Paths are relative to `/companies/:company_id/`.
  """

  use Gettext, backend: FullCircleWeb.Gettext

  alias FullCircle.Authorization

  @doc """
  Returns hub definitions visible for the current user/role/company.

  Each hub: `%{id, title, blurb, color, show?}`
  """
  def hubs(user, company, role) do
    [
      %{
        id: "sales",
        title: gettext("Sales & AR"),
        blurb: gettext("Invoices, e-invoice, receipts and sales reports"),
        color: "teal",
        show?: role != "punch_camera"
      },
      %{
        id: "purchases",
        title: gettext("Purchases & AP"),
        blurb: gettext("Purchase invoices and supplier payments"),
        color: "teal",
        show?: role != "punch_camera"
      },
      %{
        id: "cash",
        title: gettext("Cash & Bank"),
        blurb: gettext("Receipts, payments, deposits, cheques and bank recon"),
        color: "blue",
        show?: role != "punch_camera"
      },
      %{
        id: "payroll",
        title: gettext("Payroll"),
        blurb: gettext("Pay run, employees, attendance and statutory"),
        color: "orange",
        show?: role != "punch_camera"
      },
      %{
        id: "farm",
        title: gettext("Farm & Ops"),
        blurb: gettext("Harvest, egg stock, weighing and houses"),
        color: "gray",
        show?: role != "punch_camera"
      },
      %{
        id: "reports",
        title: gettext("Reports"),
        blurb: gettext("Ledgers, aging, forecasts and statements"),
        color: "red",
        show?: role != "punch_camera"
      },
      %{
        id: "masters",
        title: gettext("Masters"),
        blurb: gettext("Accounts, contacts, goods, tax and fixed assets"),
        color: "blue",
        show?: role != "punch_camera"
      },
      %{
        id: "admin",
        title: gettext("Admin"),
        blurb: gettext("Users, seeding and company tools"),
        color: "red",
        show?: role == "admin"
      }
    ]
    |> Enum.filter(& &1.show?)
    |> Enum.map(fn hub ->
      Map.drop(hub, [:show?])
    end)
    |> then(fn list ->
      # silence unused warnings if we expand user/company filters later
      _ = {user, company}
      list
    end)
  end

  @doc """
  Daily shortcuts on the home dashboard (high-frequency actions).
  """
  def quick_links(user, company, role) do
    if role == "punch_camera" do
      []
    else
      _ = {user, company}

      [
        %{label: gettext("Invoices"), path: "Invoice", class: "button teal"},
        %{label: gettext("Purchase Invoices"), path: "PurInvoice", class: "button teal"},
        %{label: gettext("E-Invoices"), path: "e_invoices", class: "button teal"},
        %{label: gettext("Receipts"), path: "Receipt", class: "button blue"},
        %{label: gettext("Payments"), path: "Payment", class: "button blue"},
        %{label: gettext("Account Transactions"), path: "account_transactions", class: "button red"},
        %{label: gettext("Contact Transactions"), path: "contact_transactions", class: "button red"},
        %{label: gettext("Salary Notes"), path: "SalaryNote", class: "button orange"},
        %{label: gettext("Pay Run"), path: "PayRun", class: "button orange"},
        %{label: gettext("Egg Stock"), path: "egg_stock", class: "button gray"}
      ]
    end
  end

  def valid_hub_id?(id, user, company, role) do
    Enum.any?(hubs(user, company, role), &(&1.id == id))
  end

  def hub_title(id, user, company, role) do
    case Enum.find(hubs(user, company, role), &(&1.id == id)) do
      nil -> gettext("Menu")
      hub -> hub.title
    end
  end

  @doc """
  Links for a hub. Each: `%{label, path, class, show?}` then filtered.
  """
  def links_for(hub_id, user, company, role) do
    hub_id
    |> do_links(user, company, role)
    |> Enum.filter(& &1.show?)
    |> Enum.map(&Map.drop(&1, [:show?]))
  end

  defp do_links("sales", _user, _company, role) do
    [
      link(gettext("Invoices"), "Invoice", "button teal"),
      link(gettext("E-Invoices"), "e_invoices", "button teal"),
      link(gettext("E-Invoice Meta Data"), "e_inv_meta", "button teal"),
      link(gettext("Good Sales"), "good_sales", "button teal"),
      link(gettext("Credit Notes"), "CreditNote", "button blue"),
      link(gettext("Debit Notes"), "DebitNote", "button blue"),
      link(gettext("Contact Statement"), "debtor_statement", "button red"),
      link(gettext("Agings"), "aging", "button red"),
      link(gettext("Goods"), "goods", "button teal", role != "punch_camera")
    ]
  end

  defp do_links("purchases", _user, _company, _role) do
    [
      link(gettext("Purchase Invoices"), "PurInvoice", "button teal"),
      link(gettext("Payments"), "Payment", "button blue"),
      link(gettext("Goods"), "goods", "button teal")
    ]
  end

  defp do_links("cash", user, company, _role) do
    [
      link(gettext("Receipts"), "Receipt", "button blue"),
      link(gettext("Payments"), "Payment", "button blue"),
      link(gettext("Deposits"), "Deposit", "button blue"),
      link(gettext("Return Cheques"), "ReturnCheque", "button blue"),
      link(gettext("Journal Entries"), "Journal", "button blue"),
      link(
        gettext("Bank Reconciliation"),
        "bank_reconciliation",
        "button blue",
        Authorization.can?(user, :view_bank_reconciliation, company)
      ),
      link(gettext("Post Dated Cheques"), "post_dated_cheque_listing", "button red")
    ]
  end

  defp do_links("payroll", _user, _company, role) do
    [
      link(gettext("Pay Run"), "PayRun", "button orange"),
      link(gettext("Employees"), "employees", "button orange"),
      link(gettext("Salary Notes"), "SalaryNote", "button orange"),
      link(gettext("Advances"), "Advance", "button orange"),
      link(gettext("Recurrings"), "recurrings", "button orange"),
      link(gettext("Salary Types"), "salary_types", "button orange"),
      link(gettext("Holiday"), "holidays", "button orange"),
      link(gettext("Import Attendence File"), "import_attend", "blue button"),
      link(gettext("Punch Card"), "PunchCard", "button orange"),
      link(gettext("Punch IO index"), "PunchIndex", "button orange"),
      link(gettext("Punching RAW Listing"), "TimeAttend", "button orange"),
      link(gettext("EPF/SOCSO/EIS"), "epfsocsoeis", "button orange"),
      link(gettext("EA Form"), "eaform", "button orange"),
      link(gettext("Statutory Calcs"), "statutory_calcs", "button orange", role == "admin")
    ]
  end

  defp do_links("farm", _user, _company, _role) do
    [
      link(gettext("Egg Stock"), "egg_stock", "button gray"),
      link(gettext("Harvest"), "harvests", "button gray"),
      link(gettext("Harvest Report"), "harvest_report", "button gray"),
      link(gettext("Harvest Wages Report"), "harvest_wage_report", "button gray"),
      link(gettext("House"), "houses", "button gray"),
      link(gettext("Flock"), "flocks", "button gray"),
      link(gettext("House Feed"), "house_feed", "button gray"),
      link(gettext("Feed vs Egg Report"), "feed_egg_report", "button gray"),
      link(gettext("Weighings"), "Weighing", "button gray"),
      link(gettext("Weight Goods Report"), "weighed_goods_report", "button gray"),
      link(gettext("Files"), "upload_files", "button gray")
    ]
  end

  defp do_links("reports", _user, _company, role) do
    [
      link(gettext("Account Transactions"), "account_transactions", "button red"),
      link(gettext("Contact Transactions"), "contact_transactions", "button red"),
      link(gettext("Contact Statement"), "debtor_statement", "button red"),
      link(gettext("Agings"), "aging", "button red"),
      link(gettext("Driver Commission"), "transport_commission", "button red"),
      link(gettext("Post Dated Cheques"), "post_dated_cheque_listing", "button red"),
      link(gettext("Fixed Assets"), "fixed_assets_report", "button red", role == "admin"),
      link(gettext("TB/PL/BS"), "tbplbs", "button red", role == "admin"),
      link(gettext("Cash Forecast"), "cash_forecast", "button red", role == "admin"),
      link(gettext("P&L Forecast"), "profit_loss_forecast", "button red", role == "admin"),
      link(gettext("Queries"), "queries", "button red", role == "admin"),
      link(gettext("Good Sales"), "good_sales", "button teal"),
      link(gettext("EPF/SOCSO/EIS"), "epfsocsoeis", "button orange"),
      link(gettext("Harvest Report"), "harvest_report", "button gray")
    ]
  end

  defp do_links("masters", _user, _company, _role) do
    [
      link(gettext("Accounts"), "accounts", "button blue"),
      link(gettext("Contacts"), "contacts", "button blue"),
      link(gettext("Goods"), "goods", "button teal"),
      link(gettext("TaxCodes"), "tax_codes", "button teal"),
      link(gettext("Fixed Assets"), "fixed_assets", "button blue")
    ]
  end

  defp do_links("admin", _user, _company, role) do
    [
      link(gettext("Seeding"), "seeds", "button red", role == "admin"),
      link(gettext("Users"), "users", "button red", role == "admin"),
      link(gettext("Rouge Users"), "rouge_users", "button red", role == "admin"),
      link(gettext("Queries"), "queries", "button red", role == "admin"),
      link(gettext("Statutory Calcs"), "statutory_calcs", "button orange", role == "admin")
    ]
  end

  defp do_links(_, _user, _company, _role), do: []

  defp link(label, path, class, show? \\ true) do
    %{label: label, path: path, class: class, show?: show?}
  end
end
