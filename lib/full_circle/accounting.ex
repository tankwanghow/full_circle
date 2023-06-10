defmodule FullCircle.Accounting do
  import Ecto.Query, warn: false

  alias FullCircle.Accounting.{
    Account,
    TaxCode,
    FixedAsset,
    Contact,
    FixedAssetDepreciation,
    Transaction
  }

  alias FullCircle.{Repo, Sys, StdInterface}
  alias FullCircle.Sys.Company

  def account_types do
    balance_sheet_account_types() ++ profit_loss_account_types()
  end

  def depreciation_intervals do
    ~w(Monthly Yearly)
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

  def journal_entries(doc_type, doc_no, company_id) do
    Repo.all(
      from txn in Transaction,
        join: acc in Account,
        on: acc.id == txn.account_id,
        left_join: con in Contact,
        on: con.id == txn.contact_id,
        where: txn.doc_type == ^doc_type,
        where: txn.doc_no == ^doc_no,
        where: txn.company_id == ^company_id,
        select: txn,
        select_merge: %{account_name: acc.name, contact_name: con.name},
        order_by: [acc.name, txn.amount]
    )
  end

  def get_tax_code!(id, company, user) do
    from(taxcode in tax_code_query(company, user),
      where: taxcode.id == ^id
    )
    |> Repo.one!()
  end

  def get_tax_code_by_code(code, company, user) do
    from(taxcode in tax_code_query(company, user),
      where: taxcode.code == ^code
    )
    |> Repo.one()
  end

  def tax_codes(terms, company, user) do
    from(taxcode in TaxCode,
      join: com in subquery(Sys.user_company(company, user)),
      on: com.id == taxcode.company_id,
      where: ilike(taxcode.code, ^"%#{terms}%"),
      select: %{id: taxcode.id, value: taxcode.code, rate: taxcode.rate}
    )
    |> Repo.all()
  end

  def sale_tax_codes(terms, company, user) do
    from(taxcode in TaxCode,
      join: com in subquery(Sys.user_company(company, user)),
      on: com.id == taxcode.company_id,
      where: ilike(taxcode.code, ^"%#{terms}%"),
      where: taxcode.tax_type == "Sales",
      select: %{id: taxcode.id, value: taxcode.code, rate: taxcode.rate}
    )
    |> Repo.all()
  end

  def purchase_tax_codes(terms, company, user) do
    from(taxcode in TaxCode,
      join: com in subquery(Sys.user_company(company, user)),
      on: com.id == taxcode.company_id,
      where: ilike(taxcode.code, ^"%#{terms}%"),
      where: taxcode.tax_type == "Purchase",
      select: %{id: taxcode.id, value: taxcode.code, rate: taxcode.rate}
    )
    |> Repo.all()
  end

  def tax_code_query(company, user) do
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

  def depreciations_query(fx_id) do
    from(dep in FixedAssetDepreciation,
      left_join: txn in Transaction,
      on: dep.transaction_id == txn.id,
      where: dep.fixed_asset_id == ^fx_id,
      select: %{
        cost_basis: dep.cost_basis,
        depre_date: dep.depre_date,
        amount: dep.amount,
        closed: fragment("COALESCE(?, false)", txn.closed),
        transaction_id: txn.id
      },
      order_by: dep.depre_date
    )
    |> Repo.all()
  end

  def generate_depreciations(fixed_asset, edate, com) do
    case fixed_asset.depre_interval do
      "Yearly" ->
        yearly_deprecaitions(fixed_asset, edate, com)

      "Monthly" ->
        monthly_deprecaitions(fixed_asset, edate, com)

      _ ->
        []
    end
  end

  defp yearly_deprecaitions(fa, edate, com) do
    depreciations = depreciations_query(fa.id)

    cume_depre =
      depreciations
      |> Enum.reduce(Decimal.new(0), fn cum, dep -> Decimal.add(cum, dep.amount) end)
      |> Decimal.to_float()

    last_depre = depreciations |> List.last()

    last_dep_year =
      if(last_depre, do: last_depre.depre_date.year + 1, else: fa.depre_start_date.year)

    yr_list =
      if edate.year >= last_dep_year do
        Enum.to_list(last_dep_year..edate.year)
        |> Enum.map(fn x -> Date.new!(x, com.closing_month, com.closing_day) end)
      else
        []
      end

    cost = fa.pur_price |> Decimal.to_float()
    rate = fa.depre_rate |> Decimal.to_float()
    resi = fa.residual_value |> Decimal.to_float()

    depreciations_list(fa, cost, cume_depre, rate, resi, yr_list)
  end

  defp monthly_deprecaitions(fa, edate, com) do
    depreciations = depreciations_query(fa.id)

    cume_depre =
      depreciations
      |> Enum.reduce(Decimal.new(0), fn cum, dep -> Decimal.add(cum, dep.amount) end)
      |> Decimal.to_float()

    last_depre = depreciations |> List.last()

    last_dep_date =
      if last_depre do
        last_depre.depre_date |> Timex.shift(months: 1)
      else
        fa.depre_start_date
      end

    range =
      if Date.compare(edate, last_dep_date) == :gt do
        Date.range(last_dep_date, edate)
        |> Enum.to_list()
        |> Enum.filter(fn x ->
          x ==
            case Date.new(x.year, x.month, com.closing_day) do
              {:ok, res} -> res
              {:error, _} -> Date.end_of_month(x)
            end
        end)
      else
        []
      end

    cost = fa.pur_price |> Decimal.to_float()
    rate = (fa.depre_rate |> Decimal.to_float()) / 12
    resi = fa.residual_value |> Decimal.to_float()

    depreciations_list(fa, cost, cume_depre, rate, resi, range)
  end

  defp depreciations_list(fa, cost, cume_depre, rate, resi, dates) do
    {depre, _} =
      dates
      |> Enum.map_reduce(cume_depre, fn y, cume_depre ->
        {cond do
           Float.round(cume_depre + cost * rate, 2) < Float.round(cost - resi, 2) ->
             {y, Float.round(cost * rate, 2)}

           Float.round(cume_depre + cost * rate, 2) >= Float.round(cost - resi, 2) ->
             if Float.round(cume_depre, 2) < Float.round(cost - resi, 2) do
               {y, Float.round(cost - cume_depre - resi, 2)}
             else
               nil
             end

           true ->
             nil
         end, Float.round(cume_depre + cost * rate, 2)}
      end)

    Enum.reject(depre, fn x -> x == nil end)
    |> Enum.map(fn {y, x} ->
      %FixedAssetDepreciation{
        fixed_asset_id: fa.id,
        depre_date: y,
        cost_basis: cost,
        amount: Decimal.new(Float.to_string(x))
      }
    end)
  end

  def get_fixed_asset!(id, company, user) do
    from(fa in fixed_asset_query(company, user),
      where: fa.id == ^id
    )
    |> Repo.one!()
  end

  def fixed_asset_query(company, user) do
    from(fa in FixedAsset,
      join: com in subquery(Sys.user_company(company, user)),
      on: com.id == fa.company_id,
      left_join: ac in Account,
      on: ac.id == fa.asset_ac_id,
      left_join: ac1 in Account,
      on: ac1.id == fa.depre_ac_id,
      left_join: ac2 in Account,
      on: ac2.id == fa.disp_fund_ac_id,
      select: %FixedAsset{
        id: fa.id,
        name: fa.name,
        depre_rate: fa.depre_rate,
        depre_method: fa.depre_method,
        depre_interval: fa.depre_interval,
        depre_start_date: fa.depre_start_date,
        pur_date: fa.pur_date,
        pur_price: fa.pur_price,
        residual_value: fa.residual_value,
        asset_ac_name: ac.name,
        asset_ac_id: ac.id,
        depre_ac_name: ac1.name,
        depre_ac_id: ac1.id,
        disp_fund_ac_name: ac2.name,
        disp_fund_ac_id: ac2.id,
        descriptions: fa.descriptions,
        inserted_at: fa.inserted_at,
        updated_at: fa.updated_at,
        company_id: com.id
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

  def get_account_by_name(name, com, user) do
    Repo.one(
      from ac in Account,
        join: com in subquery(Sys.user_company(com, user)),
        on: com.id == ac.company_id,
        where: ac.name == ^name
    )
  end

  def account_names(terms, company, user) do
    from(ac in Account,
      join: com in subquery(Sys.user_company(company, user)),
      on: com.id == ac.company_id,
      where: ilike(ac.name, ^"%#{terms}%"),
      select: %{id: ac.id, value: ac.name},
      order_by: ac.name
    )
    |> Repo.all()
  end

  def contact_names(terms, company, user) do
    from(cont in Contact,
      join: com in subquery(Sys.user_company(company, user)),
      on: com.id == cont.company_id,
      where: ilike(cont.name, ^"%#{terms}%"),
      select: %{id: cont.id, value: cont.name},
      order_by: cont.name
    )
    |> Repo.all()
  end

  def delete_account(ac, company, user) do
    if !is_default_account?(ac) do
      StdInterface.delete(Account, "account", ac, company, user)
    else
      {:error, "Cannot delete default account", StdInterface.changeset(Account, ac, %{}, company),
       ""}
    end
  end

  def is_default_account?(ac) do
    Enum.any?(Sys.default_accounts(), fn a -> a.name == ac.name end)
  end

  # def fixed_asset_draft_transactions(com) do
  #   from(txn if subquery(fixed_asset_txn_query(com)),
  #   select: txn.
  #   )
  # end

  def fixed_asset_txn_query(com) do
    from(txn in Transaction,
      join: comp in Company,
      on: comp.id == txn.company_id,
      join: acc in Account,
      on: acc.id == txn.account_id,
      where: acc.account_type == "Fixed Asset",
      where: comp.id == ^com.id,
      select: txn,
      select_merge: %{account_name: acc.name}
    )
  end

  # def unregistered_fixed_assets_count(com) do

  # end
end
