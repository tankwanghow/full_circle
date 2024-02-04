defmodule FullCircleWeb.Router do
  use FullCircleWeb, :router

  import FullCircleWeb.UserAuth
  import FullCircleWeb.Locale
  import FullCircleWeb.ActiveCompany

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, {FullCircleWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
    plug(:fetch_current_user)
    plug(:set_active_company)
    plug(:set_locale)
  end

  pipeline :api do
    plug(:accepts, ["json"])
  end

  scope "/", FullCircleWeb do
    pipe_through(:browser)

    get("/", PageController, :home)
  end

  scope "/api", FullCircleWeb do
    pipe_through(:api)
    get "/companies/:company_id/:user_id/billingtags", BillingTagController, :index
    get "/companies/:company_id/:user_id/tags", TagController, :index
    get "/companies/:company_id/:user_id/autocomplete", AutoCompleteController, :index
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:full_circle, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    # import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through(:browser)

      # live_dashboard("/dashboard", metrics: FullCircleWeb.Telemetry)
      forward("/mailbox", Plug.Swoosh.MailboxPreview)
    end
  end

  ## Authentication routes

  scope "/", FullCircleWeb do
    pipe_through([:browser, :redirect_if_user_is_authenticated])

    live_session :redirect_if_user_is_authenticated,
      on_mount: [
        {FullCircleWeb.UserAuth, :redirect_if_user_is_authenticated},
        {FullCircleWeb.Locale, :set_locale}
      ] do
      live("/users/register", UserRegistrationLive, :new)
      live("/users/log_in", UserLoginLive, :new)
      live("/users/reset_password", UserForgotPasswordLive, :new)
      live("/users/reset_password/:token", UserResetPasswordLive, :edit)
    end

    post("/users/log_in", UserSessionController, :create)
  end

  scope "/", FullCircleWeb do
    pipe_through([:browser, :require_authenticated_user])

    live_session :require_authenticated_user,
      on_mount: [
        {FullCircleWeb.UserAuth, :ensure_authenticated},
        {FullCircleWeb.Locale, :set_locale}
      ] do
      live("/users/settings", UserSettingsLive, :edit)
      live("/users/settings/confirm_email/:token", UserSettingsLive, :confirm_email)
      live("/companies", CompanyLiveIndex)
      live("/companies/new", CompanyLive.Form, :new)
      live("/edit_company/:id", CompanyLive.Form, :edit)
    end

    post("/update_active_company", ActiveCompanyController, :create)
    get("/delete_active_company", ActiveCompanyController, :delete)
  end

  scope "/companies/:company_id", FullCircleWeb do
    pipe_through([:browser, :require_authenticated_user])

    get "/csv", CsvController, :show

    live_session :require_authenticated_user_n_active_company,
      on_mount: [
        {FullCircleWeb.UserAuth, :ensure_authenticated},
        {FullCircleWeb.Locale, :set_locale},
        {FullCircleWeb.ActiveCompany, :assign_active_company}
      ] do
      live("/dashboard", DashboardLive)
      live("/users/new", UserLive.New, :new)
      live("/users", UserLive.Index, :index)
      live("/rouge_users", UserLive.RougeUserIndex, :index)

      live("/accounts", AccountLive.Index, :index)
      live("/accounts/new", AccountLive.Form, :new)
      live("/accounts/:account_id/edit", AccountLive.Form, :edit)

      live("/contacts", ContactLive.Index, :index)
      live("/contacts/new", ContactLive.Form, :new)
      live("/contacts/:contact_id/edit", ContactLive.Form, :edit)

      live("/tax_codes", TaxCodeLive.Index, :index)
      live("/tax_codes/new", TaxCodeLive.Form, :new)
      live("/tax_codes/:tax_code_id/edit", TaxCodeLive.Form, :edit)

      live("/salary_types", SalaryTypeLive.Index, :index)
      live("/salary_types/new", SalaryTypeLive.Form, :new)
      live("/salary_types/:type_id/edit", SalaryTypeLive.Form, :edit)

      live("/goods", GoodLive.Index, :index)
      live("/goods/new", GoodLive.Form, :new)
      live("/goods/:good_id/copy", GoodLive.Form, :copy)
      live("/goods/:good_id/edit", GoodLive.Form, :edit)

      live("/employees", EmployeeLive.Index, :index)
      live("/employees/new", EmployeeLive.Form, :new)
      live("/employees/:employee_id/copy", EmployeeLive.Form, :copy)
      live("/employees/:employee_id/edit", EmployeeLive.Form, :edit)

      live("/houses", LayerLive.HouseIndex, :index)
      live("/houses/new", LayerLive.HouseForm, :new)
      live("/houses/:house_id/edit", LayerLive.HouseForm, :edit)

      live("/flocks", LayerLive.FlockIndex, :index)
      live("/flocks/new", LayerLive.FlockForm, :new)
      live("/flocks/:flock_id/edit", LayerLive.FlockForm, :edit)

      live("/holidays", HolidayLive.Index, :index)
      live("/holidays/new", HolidayLive.Form, :new)
      live("/holidays/:holiday_id/copy", HolidayLive.Form, :copy)
      live("/holidays/:holiday_id/edit", HolidayLive.Form, :edit)

      live("/fixed_assets", FixedAssetLive.Index, :index)
      live("/fixed_assets/new", FixedAssetLive.Form, :new)
      live("/fixed_assets/:asset_id/edit", FixedAssetLive.Form, :edit)
      live("/fixed_assets/:id/depreciations", FixedAssetLive.Depreciations, :index)
      live("/fixed_assets/:id/disposals", FixedAssetLive.Disposals, :index)
      live("/fixed_assets/calalldepre", FixedAssetLive.CalAllDepre, :index)

      live("/Invoice", InvoiceLive.Index, :index)
      live("/Invoice/new", InvoiceLive.Form, :new)
      live("/Invoice/:invoice_id/edit", InvoiceLive.Form, :edit)

      live("/Delivery", DeliveryLive.Index, :index)
      live("/Delivery/new", DeliveryLive.Form, :new)
      live("/Delivery/:delivery_id/edit", DeliveryLive.Form, :edit)

      live("/Order", OrderLive.Index, :index)
      live("/Order/new", OrderLive.Form, :new)
      live("/Order/:order_id/edit", OrderLive.Form, :edit)

      live("/Load", LoadLive.Index, :index)
      live("/Load/new", LoadLive.Form, :new)
      live("/Load/:load_id/edit", LoadLive.Form, :edit)

      live("/Advance", AdvanceLive.Index, :index)
      live("/Advance/new", AdvanceLive.Form, :new)
      live("/Advance/:slip_id/edit", AdvanceLive.Form, :edit)

      live("/SalaryNote", SalaryNoteLive.Index, :index)
      live("/SalaryNote/new", SalaryNoteLive.Form, :new)
      live("/SalaryNote/:slip_id/edit", SalaryNoteLive.Form, :edit)

      live("/PurInvoice", PurInvoiceLive.Index, :index)
      live("/PurInvoice/new", PurInvoiceLive.Form, :new)
      live("/PurInvoice/:invoice_id/edit", PurInvoiceLive.Form, :edit)

      live("/logs/:entity/:entity_id", LogLive.Index, :index)
      live("/journal_entries/:doc_type/:doc_no", JournalEntryViewLive.Index, :index)

      live("/account_transactions", ReportLive.Account, :index)
      live("/contact_transactions", ReportLive.Contact, :index)
      live("/debtor_statement", ReportLive.Statement, :index)
      live("/harvest_report", LayerLive.HarvestReport, :index)
      live("/harvest_wage_report", LayerLive.HarvestWageReport, :index)
      live("/weighed_goods_report", WeighingLive.GoodsReport, :index)
      live("/transport_commission", ReportLive.TransportCommission, :index)
      live("/epfsocsoeis", ReportLive.EpfSocsoEis, :index)
      live("/good_sales", ReportLive.GoodSales, :index)
      live("/feed_listing", ReportLive.HouseFeedTypes, :index)

      live("/tbplbs", ReportLive.TbPlBs, :index)
      live("/aging", ReportLive.Aging, :index)

      live("/Deposit", ChequeLive.DepositIndex, :index)
      live("/Deposit/new", ChequeLive.DepositForm, :new)
      live("/Deposit/:deposit_id/edit", ChequeLive.DepositForm, :edit)

      live("/ReturnCheque", ChequeLive.ReturnChequeIndex, :index)
      live("/ReturnCheque/new", ChequeLive.ReturnChequeForm, :new)
      live("/ReturnCheque/:return_id/edit", ChequeLive.ReturnChequeForm, :edit)

      live("/CreditNote", CreditNoteLive.Index, :index)
      live("/CreditNote/new", CreditNoteLive.Form, :new)
      live("/CreditNote/:note_id/edit", CreditNoteLive.Form, :edit)

      live("/DebitNote", DebitNoteLive.Index, :index)
      live("/DebitNote/new", DebitNoteLive.Form, :new)
      live("/DebitNote/:note_id/edit", DebitNoteLive.Form, :edit)

      live("/seeds", SeedLive.Index, :index)
      live("/seeds/:doc_type/:doc_no/edit", SeedLive.Form, :edit)

      live("/Receipt", ReceiptLive.Index, :index)
      live("/Receipt/new", ReceiptLive.Form, :new)
      live("/Receipt/:receipt_id/edit", ReceiptLive.Form, :edit)

      live("/recurrings", RecurringLive.Index, :index)
      live("/recurrings/new", RecurringLive.Form, :new)
      live("/recurrings/:recur_id/edit", RecurringLive.Form, :edit)

      live("/Payment", PaymentLive.Index, :index)
      live("/Payment/new", PaymentLive.Form, :new)
      live("/Payment/:payment_id/edit", PaymentLive.Form, :edit)

      live("/TimeAttend", TimeAttendLive.Index, :index)
      live("/TimeAttend/new", TimeAttendLive.Form, :new)
      live("/TimeAttend/:attend_id/edit", TimeAttendLive.Form, :edit)

      live("/PunchIndex", TimeAttendLive.PunchIndex, :index)
      live("/PunchCard", TimeAttendLive.PunchCard, :index)

      live("/Journal", JournalLive.Index, :index)
      live("/Journal/new", JournalLive.Form, :new)
      live("/Journal/:journal_id/edit", JournalLive.Form, :edit)

      live("/Weighing", WeighingLive.Index, :index)
      live("/Weighing/new", WeighingLive.Form, :new)
      live("/Weighing/:weighing_id/edit", WeighingLive.Form, :edit)

      live("/harvests", LayerLive.HarvestIndex, :index)
      live("/harvests/new", LayerLive.HarvestForm, :new)
      live("/harvests/:harvest_id/edit", LayerLive.HarvestForm, :edit)

      live("/PayRun", PayRunLive.Index, :index)

      live("/PaySlip/new", PaySlipLive.Form, :new)
      live("/PaySlip/:pay_slip_id/recal", PaySlipLive.Form, :recal)
      live("/PaySlip/:pay_slip_id/view", PaySlipLive.Form, :view)

      live("/upload_files", UploadFileLive.Index, :index)
    end

    live_session :require_authenticated_user_n_active_company_print,
      on_mount: [
        {FullCircleWeb.UserAuth, :ensure_authenticated},
        {FullCircleWeb.Locale, :set_locale},
        {FullCircleWeb.ActiveCompany, :assign_active_company}
      ],
      root_layout: {FullCircleWeb.Layouts, :print_root} do
      live("/Invoice/:id/print", InvoiceLive.Print, :print)
      live("/Invoice/print_multi", InvoiceLive.Print, :print)

      live("/Receipt/:id/print", ReceiptLive.Print, :print)
      live("/Receipt/print_multi", ReceiptLive.Print, :print)

      live("/Payment/:id/print", PaymentLive.Print, :print)
      live("/Payment/print_multi", PaymentLive.Print, :print)

      live("/ReturnCheque/:id/print", ChequeLive.ReturnChequePrint, :print)
      live("/ReturnCheque/print_multi", ChequeLive.ReturnChequePrint, :print)

      live("/CreditNote/:id/print", CreditNoteLive.Print, :print)
      live("/CreditNote/print_multi", CreditNoteLive.Print, :print)

      live("/DebitNote/:id/print", DebitNoteLive.Print, :print)
      live("/DebitNote/print_multi", DebitNoteLive.Print, :print)

      live("/Advance/:id/print", AdvanceLive.Print, :print)
      live("/Advance/print_multi", AdvanceLive.Print, :print)

      live("/SalaryNote/:id/print", SalaryNoteLive.Print, :print)
      live("/SalaryNote/print_multi", SalaryNoteLive.Print, :print)

      live("/Journal/:id/print", JournalLive.Print, :print)
      live("/Journal/print_multi", JournalLive.Print, :print)

      live("/employees/:id/print", EmployeeLive.Print, :print)
      live("/employees/print_multi", EmployeeLive.Print, :print)

      live("/PaySlip/:id/print", PaySlipLive.Print, :print)
      live("/PaySlip/print_multi", PaySlipLive.Print, :print)

      live("/Load/:id/print", LoadLive.Print, :print)
      live("/Load/print_multi", LoadLive.Print, :print)

      live("/Order/:id/print", OrderLive.Print, :print)
      live("/Order/print_multi", OrderLive.Print, :print)

      live("/Delivery/:id/print", DeliveryLive.Print, :print)
      live("/Delivery/print_multi", DeliveryLive.Print, :print)

      live("/Weighing/:id/print", WeighingLive.Print, :print)
      live("/Weighing/print_multi", WeighingLive.Print, :print)

      live("/Statement/print_multi", ReportLive.Statement.Print, :print)

      live("/print/transactions", ReportLive.Print, :print)
      live("/print/harvrepo", LayerLive.HarvestReportPrint, :print)
      live("/print/harvwagrepo", LayerLive.HarvestWageReportPrint, :print)
      live("/print/tbplbs", ReportLive.TbPlBs, :print)
    end

    live_session :require_authenticated_user_n_active_company_punch,
      on_mount: [
        {FullCircleWeb.UserAuth, :ensure_authenticated},
        {FullCircleWeb.Locale, :set_locale},
        {FullCircleWeb.ActiveCompany, :assign_active_company}
      ],
      root_layout: {FullCircleWeb.Layouts, :punch} do
      live("/PunchCamera", TimeAttendLive.PunchCamera)
    end
  end

  scope "/", FullCircleWeb do
    pipe_through([:browser])

    delete("/users/log_out", UserSessionController, :delete)

    live_session :current_user,
      on_mount: [{FullCircleWeb.UserAuth, :mount_current_user}] do
      live("/users/confirm/:token", UserConfirmationLive, :edit)
      live("/users/confirm", UserConfirmationInstructionsLive, :new)
    end
  end
end
