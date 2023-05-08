defmodule FullCircle.Accounting do
  import Ecto.Query, warn: false

  alias FullCircle.Accounting.{Account, TaxCode, FixedAsset, Contact}
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

  alias FullCircle.Accounting.Transaction

  def journal_entries(doc_type, doc_no, company, user) do
    Repo.all(
      from txn in Transaction,
        join: com in subquery(Sys.user_company(company, user)),
        on: com.id == txn.company_id,
        join: acc in Account,
        on: acc.id == txn.account_id,
        left_join: con in Contact,
        on: con.id == txn.contact_id,
        where: txn.doc_type == ^doc_type,
        where: txn.doc_no == ^doc_no,
        select: txn,
        select_merge: %{account_name: acc.name, contact_name: con.name},
        order_by: [acc.name, txn.amount]
    )
  end

  def get_tax_code!(id, user, company) do
    from(taxcode in tax_code_query(user, company),
      where: taxcode.id == ^id
    )
    |> Repo.one!()
  end

  def tax_codes(terms, user, company) do
    terms = terms |> String.splitter("") |> Enum.join("%")
    from(taxcode in TaxCode,
      join: com in subquery(Sys.user_company(company, user)),
      on: com.id == taxcode.company_id,
      where: ilike(taxcode.code, ^"#{terms}"),
      select: %{id: taxcode.id, value: taxcode.code, rate: taxcode.rate}
    )
    |> Repo.all()
  end

  def tax_code_query(user, company) do
    from(taxcode in TaxCode,
      join: com in subquery(Sys.user_company(company, user)),
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

  def get_fixed_asset!(id, user, company) do
    from(fa in fixed_asset_query(user, company),
      where: fa.id == ^id
    )
    |> Repo.one!()
  end

  def fixed_asset_query(user, company) do
    from(fa in FixedAsset,
      join: com in subquery(Sys.user_company(company, user)),
      on: com.id == fa.company_id,
      left_join: ac in Account,
      on: ac.id == fa.asset_ac_id,
      left_join: ac1 in Account,
      on: ac1.id == fa.depre_ac_id,
      left_join: ac2 in Account,
      on: ac2.id == fa.cume_depre_ac_id,
      select: %FixedAsset{
        id: fa.id,
        name: fa.name,
        depre_rate: fa.depre_rate,
        depre_method: fa.depre_method,
        pur_date: fa.pur_date,
        pur_price: fa.pur_price,
        depre_start_date: fa.depre_start_date,
        residual_value: fa.residual_value,
        asset_ac_name: ac.name,
        asset_ac_id: ac.id,
        depre_ac_name: ac1.name,
        depre_ac_id: ac1.id,
        cume_depre_ac_name: ac2.name,
        cume_depre_ac_id: ac2.id,
        descriptions: fa.descriptions,
        inserted_at: fa.inserted_at,
        updated_at: fa.updated_at
      }
    )
  end

  def get_account_by_name!(name, com, user) do
    Repo.one!(
      from ac in Account,
        join: com in subquery(Sys.user_company(com, user)),
        on: com.id == ac.company_id,
        where: ac.name == ^name
    )
  end

  def account_names(terms, user, company) do
    terms = terms |> String.splitter("") |> Enum.join("%")
    from(ac in Account,
      join: com in subquery(Sys.user_company(company, user)),
      on: com.id == ac.company_id,
      where: ilike(ac.name, ^"#{terms}"),
      select: %{id: ac.id, value: ac.name},
      order_by: ac.name
    )
    |> Repo.all()
  end

  def contact_names(terms, user, company) do
    terms = terms |> String.splitter("") |> Enum.join("%")
    from(cont in Contact,
      join: com in subquery(Sys.user_company(company, user)),
      on: com.id == cont.company_id,
      where: ilike(cont.name, ^"#{terms}"),
      select: %{id: cont.id, value: cont.name},
      order_by: cont.name
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
