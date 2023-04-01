defmodule FullCircle.Accounting do
  def account_types do
    balance_sheet_account_types() ++ profit_loss_account_types()
  end

  defp balance_sheet_account_types do
    [
      "Cash or Equivalent",
      "Bank",
      "Current Asset",
      "Fixed Asset",
      "Inventory",
      "Non-current Asset",
      "Prepayment",
      "Equity",
      "Current Liability",
      "Liability",
      "Non-current Liability"
    ]
  end

  defp profit_loss_account_types do
    ["Depreciation", "Direct Costs", "Expenses", "Overhead", "Other Income", "Revenue", "Sales"]
  end

  def depreciation_methods do
    [
      "No Depreciation",
      "Straight-Line",
      "Declining Balance",
      "Declining Balance 150%",
      "Declining Balance 200%",
      "Full Depreciation at Purchase"
    ]
  end
end
