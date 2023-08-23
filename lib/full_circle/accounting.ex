defmodule FullCircle.Accounting do
  import Ecto.Query, warn: false
  import FullCircleWeb.Gettext
  import FullCircle.Authorization

  alias Ecto.Multi

  alias FullCircle.Accounting.{
    Account,
    TaxCode,
    FixedAsset,
    Contact,
    FixedAssetDepreciation,
    FixedAssetDisposal,
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

  def balance_sheet_account_types do
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
      "Non-current Liability",
      "Intangible Asset",
      "Accrual",
      "Post Dated Cheques"
    ]
  end

  def profit_loss_account_types do
    [
      "Depreciation",
      "Direct Costs",
      "Expenses",
      "Overhead",
      "Other Income",
      "Revenue",
      "Cost Of Goods Sold"
    ]
  end

  def depreciation_methods do
    [
      "No Depreciation",
      "Straight-Line"
    ]
  end

  def is_balance_sheet_account?(ac) do
    bst = balance_sheet_account_types()
    Enum.any?(bst, fn x -> x == ac.account_type end)
  end

  def query_transactions_for_matching(ctid, sdate, edate, com, user) do
    qry =
      from txn in subquery(transaction_with_balance_query(com, user)),
        where: txn.contact_id == ^ctid,
        where: txn.doc_date >= ^sdate,
        where: txn.doc_date <= ^edate,
        # where: txn.amount > 0,
        order_by: txn.doc_date,
        select: %{
          account_id: txn.account_id,
          transaction_id: txn.id,
          t_doc_date: txn.doc_date,
          t_doc_type: txn.doc_type,
          t_doc_no: txn.doc_no,
          t_doc_id: txn.doc_id,
          amount: txn.amount,
          particulars: txn.particulars,
          all_matched_amount: txn.all_matched_amount,
          balance: txn.amount + txn.all_matched_amount,
          match_amount: 0,
          old_data: txn.old_data
        }

    qry |> Repo.all()
  end

  def transaction_with_balance_query(com, user) do
    from txn in Transaction,
      join: comp in subquery(Sys.user_company(com, user)),
      on: txn.company_id == comp.id,
      left_join: stxm in FullCircle.Accounting.SeedTransactionMatcher,
      on: stxm.transaction_id == txn.id,
      left_join: atxm in FullCircle.Accounting.TransactionMatcher,
      on: atxm.transaction_id == txn.id,
      select: %{
        id: txn.id,
        account_id: txn.account_id,
        contact_id: txn.contact_id,
        fixed_asset_id: txn.fixed_asset_id,
        doc_date: txn.doc_date,
        doc_type: txn.doc_type,
        doc_no: txn.doc_no,
        doc_id: txn.doc_id,
        old_data: txn.old_data,
        amount:
          fragment(
            "round(?, 2)",
            txn.amount
          ),
        particulars: coalesce(txn.contact_particulars, txn.particulars),
        all_matched_amount:
          fragment(
            "round(?, 2)",
            coalesce(sum(stxm.match_amount), 0) +
              coalesce(sum(atxm.match_amount), 0)
          )
      },
      group_by: [
        txn.id
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
    code = code |> String.trim()

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
      join: fa in FixedAsset,
      on: fa.id == dep.fixed_asset_id,
      left_join: txn in Transaction,
      on: txn.doc_type == "fixed_asset_depreciations",
      on: txn.doc_date == dep.depre_date,
      on: dep.doc_no == txn.doc_no,
      where: fa.id == ^fx_id,
      where: coalesce(txn.amount, dep.amount) > 0,
      distinct: true,
      select: %{
        id: dep.id,
        cost_basis: dep.cost_basis,
        depre_date: dep.depre_date,
        amount: dep.amount,
        is_seed: dep.is_seed,
        closed: coalesce(txn.closed, false),
        doc_no: dep.doc_no,
        cume_depre:
          fragment(
            "SUM(?) OVER (PARTITION BY ? ORDER BY ?)",
            dep.amount,
            dep.fixed_asset_id,
            dep.depre_date
          )
      },
      order_by: dep.depre_date
    )
    |> Repo.all()
  end

  def disposals_query(fx_id) do
    from(disp in FixedAssetDisposal,
      where: disp.fixed_asset_id == ^fx_id,
      select: %{
        id: disp.id,
        disp_date: disp.disp_date,
        amount: disp.amount,
        is_seed: disp.is_seed,
        doc_no: disp.doc_no
      },
      order_by: disp.disp_date
    )
    |> Repo.all()
  end

  def generate_depreciations_for_all_fixed_assets(edate, com, user) do
    fixed_assets = fixed_asset_query(com, user) |> Repo.all()
    fixed_assets = Enum.reject(fixed_assets, fn fa -> Decimal.to_float(fa.depre_rate) <= 0 end)

    Enum.flat_map(fixed_assets, fn fa ->
      generate_depreciations(fa, edate, com)
    end)
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

  def depreciation_dates(fa, com) when fa.depre_interval == "Yearly" do
    depreciations = depreciations_query(fa.id)
    last_depre = depreciations |> List.last()

    {dd, k} = if(last_depre, do: {last_depre.depre_date, 1}, else: {fa.depre_start_date, 0})

    last_dep_date =
      case Date.new(dd.year, com.closing_month, com.closing_day) do
        {:ok, res} -> res
        {:error, _} -> Date.end_of_month(dd)
      end

    diff = Timex.diff(last_dep_date, fa.depre_start_date, :year)
    n = 1 / Decimal.to_float(fa.depre_rate) - diff
    n = if(n > 0, do: n, else: k)

    {Enum.to_list(k..trunc(n))
     |> Enum.map(fn x -> Timex.shift(last_dep_date, years: x) end), last_depre}
  end

  def depreciation_dates(fa, com) when fa.depre_interval == "Monthly" do
    depreciations = depreciations_query(fa.id)
    last_depre = depreciations |> List.last()

    {dd, k} = if(last_depre, do: {last_depre.depre_date, 1}, else: {fa.depre_start_date, 0})

    last_dep_date =
      case Date.new(dd.year, dd.month, com.closing_day) do
        {:ok, res} -> res
        {:error, _} -> Date.end_of_month(dd)
      end

    diff = Timex.diff(last_dep_date, fa.depre_start_date, :month)
    n = 1 / Decimal.to_float(fa.depre_rate) * 12 - diff
    n = if(n > 0, do: n, else: k)

    {Enum.to_list(k..trunc(n))
     |> Enum.map(fn x -> Timex.shift(last_dep_date, months: x) end), last_depre}
  end

  defp yearly_deprecaitions(fa, edate, com) do
    {range, last_depre} = depreciation_dates(fa, com)
    cume_depre = if(last_depre, do: last_depre.cume_depre |> Decimal.to_float(), else: 0.0)

    range = Enum.reject(range, fn d -> Date.compare(d, edate) == :gt end)

    cost = fa.pur_price |> Decimal.to_float()
    rate = fa.depre_rate |> Decimal.to_float()
    resi = fa.residual_value |> Decimal.to_float()

    depreciations_list(fa, cost, cume_depre, rate, resi, range)
  end

  defp monthly_deprecaitions(fa, edate, com) do
    {range, last_depre} = depreciation_dates(fa, com)
    cume_depre = if(last_depre, do: last_depre.cume_depre |> Decimal.to_float(), else: 0.0)

    range = Enum.reject(range, fn d -> Date.compare(d, edate) == :gt end)

    cost = fa.pur_price |> Decimal.to_float()
    rate = (fa.depre_rate |> Decimal.to_float()) / 12
    resi = fa.residual_value |> Decimal.to_float()

    depreciations_list(fa, cost, cume_depre, rate, resi, range)
  end

  defp depreciations_list(fa, cost, cume_depre, rate, resi, dates) do
    {depre, _} =
      dates
      |> Enum.map_reduce(cume_depre, fn y, cume_depre ->
        disp = sum_disposals(fa, y).amount |> Decimal.to_float()
        cost = cost - disp
        cume = Float.round(cume_depre + cost * rate, 2)
        depre = Float.round(cost * rate, 2)
        cost_resi = Float.round(cost - resi, 2)

        {cond do
           cume < cost_resi ->
             {y, cost, depre, cume}

           cume >= cost_resi ->
             if Float.round(cume_depre, 2) < cost_resi do
               {y, cost, Float.round(cost - cume_depre - resi, 2),
                cume_depre + Float.round(cost - cume_depre - resi, 2)}
             else
               nil
             end

           true ->
             nil
         end, Float.round(cume_depre + cost * rate, 2)}
      end)

    Enum.reject(depre, fn x -> x == nil end)
    |> Enum.map(fn {dt, cost, dep, cume} ->
      %{
        fixed_asset_id: fa.id,
        fixed_asset: fa,
        depre_date: dt |> Timex.format!("%Y-%m-%d", :strftime),
        cost_basis: cost,
        amount: dep,
        cume_depre: cume
      }
    end)
  end

  def sum_disposals(fa, ed) do
    from(disp in FixedAssetDisposal,
      where: disp.fixed_asset_id == ^fa.id,
      where: disp.disp_date <= ^ed,
      select: %{
        amount: coalesce(sum(disp.amount), 0)
      }
    )
    |> Repo.one!()
  end

  def get_fixed_asset!(id, company, user) do
    from(fa in fixed_asset_query(company, user),
      where: fa.id == ^id
    )
    |> Repo.one!()
  end

  def get_fixed_asset!(id) do
    from(fa in FixedAsset,
      where: fa.id == ^id
    )
    |> Repo.one!()
  end

  def get_fixed_asset_depreciation!(id) do
    from(fad in FixedAssetDepreciation,
      where: fad.id == ^id
    )
    |> Repo.one!()
  end

  def get_fixed_asset_disposal!(id) do
    from(fad in FixedAssetDisposal,
      where: fad.id == ^id
    )
    |> Repo.one!()
  end

  def get_fixed_asset_by_name(name, company, user) do
    name = name |> String.trim()

    from(fa in fixed_asset_query(company, user),
      where: fa.name == ^name
    )
    |> Repo.one()
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
      left_join: ac3 in Account,
      on: ac3.id == fa.cume_depre_ac_id,
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
        cume_depre_ac_name: ac3.name,
        cume_depre_ac_id: ac3.id,
        disp_fund_ac_name: ac2.name,
        disp_fund_ac_id: ac2.id,
        descriptions: fa.descriptions,
        inserted_at: fa.inserted_at,
        updated_at: fa.updated_at,
        company_id: com.id,
        cume_disp:
          fragment(
            "select COALESCE(sum(amount), 0) from fixed_asset_disposals where fixed_asset_id = ?",
            fa.id
          ),
        cume_depre:
          fragment(
            "select COALESCE(sum(amount), 0) from fixed_asset_depreciations where fixed_asset_id = ?",
            fa.id
          )
      }
    )
  end

  def get_account_by_name(name, com, user) do
    name = name |> String.trim()

    Repo.one(
      from ac in Account,
        join: com in subquery(Sys.user_company(com, user)),
        on: com.id == ac.company_id,
        where: ac.name == ^name
    )
  end

  def funds_account_names(terms, com, user) do
    from(ac in Account,
      join: com in subquery(Sys.user_company(com, user)),
      on: com.id == ac.company_id,
      where: ilike(ac.name, ^"%#{terms}%"),
      where: ac.account_type in ["Cash or Equivalent", "Bank"],
      select: %{id: ac.id, value: ac.name},
      order_by: ac.name
    )
    |> Repo.all()
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

  def get_contact_by_name(name, com, user) do
    name = name |> String.trim()

    Repo.one(
      from ct in Contact,
        join: com in subquery(Sys.user_company(com, user)),
        on: com.id == ct.company_id,
        where: ct.name == ^name
    )
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

  def is_default_tax_code?(tx) do
    Enum.any?(Sys.default_tax_codes(), fn a -> a.code == tx.code end)
  end

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

  def validate_depre_date(changeset, field) do
    fid = Ecto.Changeset.fetch_field!(changeset, :fixed_asset_id)

    if is_nil(fid) do
      changeset
    else
      qry =
        from(fad in "fixed_asset_depreciations",
          where: fad.fixed_asset_id == ^Ecto.UUID.dump!(fid)
        )

      id = Ecto.Changeset.fetch_field!(changeset, :id)
      qry = if(id, do: qry |> where([f], f.id != ^Ecto.UUID.dump!(id)), else: qry)

      dep_date = Ecto.Changeset.fetch_field!(changeset, field)
      qry = if(dep_date, do: qry |> where([f], f.depre_date == ^dep_date), else: qry)

      if FullCircle.Repo.exists?(qry) do
        Ecto.Changeset.add_error(changeset, field, gettext("same depreciation date existed"))
      else
        changeset
      end
    end
  end

  def validate_earlier_than_depreciation_start_date(changeset, field) do
    fid = Ecto.Changeset.fetch_field!(changeset, :fixed_asset_id)

    if is_nil(fid) do
      changeset
    else
      ass = FullCircle.Accounting.get_fixed_asset!(fid)

      dep_date = Ecto.Changeset.fetch_field!(changeset, field)

      if !is_nil(dep_date) and Date.compare(ass.depre_start_date, dep_date) == :gt do
        Ecto.Changeset.add_error(
          changeset,
          field,
          gettext("cannot be earlier than ") <> Date.to_iso8601(ass.depre_start_date)
        )
      else
        changeset
      end
    end
  end

  def save_generated_all_fixed_asset_depreciation(entries, com, user) do
    name = "create_fixed_asset_depreciation"

    case can?(user, :create_fixed_asset_depreciation, com) do
      true ->
        Enum.reduce(entries, Multi.new(), fn entry, multi ->
          name_entry = String.to_atom(name <> entry.depre_date <> entry.fixed_asset.name)
          doc_no = FullCircle.Helpers.gen_temp_id(10)

          multi
          |> Multi.insert(
            name_entry,
            FixedAssetDepreciation.changeset(
              %FixedAssetDepreciation{},
              Map.merge(entry, %{doc_no: doc_no})
            )
          )
          |> Sys.insert_log_for(name_entry, Map.delete(entry, :fixed_asset), com, user)
          |> create_fixed_asset_depreciation_transactions(name_entry, entry.fixed_asset, com)
        end)
        |> Repo.transaction()

      false ->
        :not_authorise
    end
  end

  def save_generated_fixed_asset_depreciation(entries, com, user) do
    name = "create_fixed_asset_depreciation"

    case can?(user, :create_fixed_asset_depreciation, com) do
      true ->
        Enum.reduce(entries, Multi.new(), fn entry, multi ->
          name_entry = String.to_atom(name <> entry.depre_date)
          doc_no = FullCircle.Helpers.gen_temp_id(10)

          multi
          |> Multi.insert(
            name_entry,
            FixedAssetDepreciation.changeset(
              %FixedAssetDepreciation{},
              Map.merge(entry, %{doc_no: doc_no})
            )
          )
          |> Sys.insert_log_for(name_entry, Map.delete(entry, :fixed_asset), com, user)
          |> create_fixed_asset_depreciation_transactions(name_entry, entry.fixed_asset, com)
        end)
        |> Repo.transaction()

      false ->
        :not_authorise
    end
  end

  def create_fixed_asset_depreciation(attrs, fa, com, user) do
    case can?(user, :create_fixed_asset_depreciation, com) do
      true ->
        try do
          Multi.new()
          |> create_fixed_asset_depreciation_multi(attrs, fa, com, user)
          |> Repo.transaction()
        rescue
          e in Postgrex.Error -> {:error, :catched, %{}, e}
        end

      false ->
        :not_authorise
    end
  end

  defp create_fixed_asset_depreciation_multi(multi, attrs, fa, com, user) do
    name = :create_fixed_asset_depreciation
    doc_no = FullCircle.Helpers.gen_temp_id(10)

    multi =
      multi
      |> Multi.insert(
        name,
        FixedAssetDepreciation.changeset(
          %FixedAssetDepreciation{},
          Map.merge(attrs, %{"doc_no" => doc_no})
        )
      )
      |> Sys.insert_log_for(name, attrs, com, user)

    if attrs["is_seed"] == "false" do
      multi
      |> create_fixed_asset_depreciation_transactions(name, fa, com)
    else
      multi
    end
  end

  defp create_fixed_asset_depreciation_transactions(multi, name, fa, com) do
    multi
    |> Ecto.Multi.run(Atom.to_string(name) <> "transactions", fn repo, %{^name => depre} ->
      repo.insert!(%Transaction{
        doc_type: "fixed_asset_depreciations",
        doc_no: depre.doc_no,
        doc_date: depre.depre_date,
        account_id: fa.depre_ac_id,
        company_id: com.id,
        amount: depre.amount,
        fixed_asset_id: fa.id,
        particulars: "Depreciation #{fa.depre_rate} on #{fa.name}"
      })

      repo.insert!(%Transaction{
        doc_type: "fixed_asset_depreciations",
        doc_no: depre.doc_no,
        doc_date: depre.depre_date,
        account_id: fa.cume_depre_ac_id,
        company_id: com.id,
        amount: Decimal.negate(depre.amount),
        fixed_asset_id: fa.id,
        particulars: "Depreciation #{fa.depre_rate} on #{fa.name}"
      })

      {:ok, nil}
    end)
  end

  def update_fixed_asset_depreciation(%FixedAssetDepreciation{} = fad, attrs, fa, com, user) do
    case can?(user, :update_fixed_asset_depreciation, com) do
      true ->
        try do
          Multi.new()
          |> update_fixed_asset_depreciation_multi(fad, attrs, fa, com, user)
          |> Repo.transaction()
        rescue
          e in Postgrex.Error -> {:error, :catched, %{}, e.postgres}
        end

      false ->
        :not_authorise
    end
  end

  def update_fixed_asset_depreciation_multi(multi, fad, attrs, fa, com, user) do
    name = :update_fixed_asset_depreciation

    multi =
      multi
      |> Multi.update(name, FixedAssetDepreciation.changeset(fad, attrs))
      |> Sys.insert_log_for(name, attrs, com, user)
      |> Multi.delete_all(
        :delete_transaction,
        from(txn in Transaction,
          where: txn.doc_type == "fixed_asset_depreciations",
          where: txn.doc_no == ^fad.doc_no,
          where: txn.company_id == ^com.id
        )
      )

    if attrs["is_seed"] == "false" do
      multi
      |> create_fixed_asset_depreciation_transactions(name, fa, com)
    else
      multi
    end
  end

  def delete_fixed_asset_depreciation(fad, company, user) do
    action = :delete_fixed_asset_depreciation
    changeset = FixedAssetDepreciation.changeset(fad, %{})

    case can?(user, action, company) do
      true ->
        try do
          Multi.new()
          |> Multi.delete(action, changeset)
          |> Multi.delete_all(
            :delete_transaction,
            from(txn in Transaction,
              where: txn.doc_type == "fixed_asset_depreciations",
              where: txn.doc_no == ^fad.doc_no,
              where: txn.company_id == ^company.id
            )
          )
          |> Sys.insert_log_for(action, %{"deleted_id_is" => fad.id}, company, user)
          |> FullCircle.Repo.transaction()
          |> case do
            {:ok, %{^action => fad}} ->
              {:ok, fad}

            {:error, failed_operation, failed_value, changes_of_far} ->
              {:error, failed_operation, failed_value, changes_of_far}
          end
        rescue
          e in Postgrex.Error -> {:error, :catched, %{}, e.postgres}
        end

      false ->
        :not_authorise
    end
  end
end
