defmodule FullCircle.Accounting do
  import Ecto.Query, warn: false

  alias FullCircle.Accounting.{Account, TaxCode}
  alias FullCircle.{Repo, Sys, StdInterface}

  def account_types do
    balance_sheet_account_types() ++ profit_loss_account_types()
  end

  def tax_types do
    ~w(Sales Purchase)
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

  def get_tax_code!(id, user, company) do
    from(taxcode in tax_code_query(user, company),
      where: taxcode.id == ^id
    )
    |> Repo.one!()
  end

  def tax_codes(terms, user, company) do
    from(taxcode in subquery(tax_code_query(user, company)),
      where: ilike(taxcode.code, ^"%#{terms}%"),
      select: %{id: taxcode.id, value: taxcode.code}
    )
    |> Repo.all()
  end

  def tax_code_query(user, company) do
    from(taxcode in TaxCode,
      join: com in subquery(Sys.user_companies(company, user)),
      on: com.id == taxcode.company_id,
      left_join: ac in Account,
      on: ac.id == taxcode.account_id,
      select: %TaxCode{
        id: taxcode.id,
        code: taxcode.code,
        rate: taxcode.rate,
        tax_type: taxcode.tax_type,
        account_name: ac.name,
        account_id: ac.id,
        descriptions: taxcode.descriptions,
        inserted_at: taxcode.inserted_at,
        updated_at: taxcode.updated_at
      }
    )
  end

  def account_names(terms, user, company) do
    from(ac in Account,
      join: com in subquery(Sys.user_companies(company, user)),
      on: com.id == ac.company_id,
      where: ilike(ac.name, ^"%#{terms}%"),
      select: %{id: ac.id, value: ac.name},
      order_by: ac.name
    )
    |> Repo.all()
  end

  def delete_account(ac, user, company) do
    if !is_default_account?(ac) do
      StdInterface.delete(Account, "account", ac, user, company)
    else
      {:error, "Cannot delete default account", StdInterface.changeset(Account, ac, %{}, company),
       ""}
    end
  end

  def is_default_account?(ac) do
    Enum.any?(Sys.default_accounts(), fn a -> a.name == ac.name end)
  end
end
