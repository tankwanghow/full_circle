defmodule FullCircle.Seeding do
  import Ecto.Query, warn: false
  import FullCircle.Authorization

  alias FullCircle.WeightBridge.Weighing
  alias FullCircle.Accounting.FixedAssetDepreciation
  alias FullCircle.Repo
  alias FullCircle.HR.{Employee, SalaryType, EmployeeSalaryType}

  alias FullCircle.Accounting.{
    TaxCode,
    Account,
    Contact,
    Transaction,
    FixedAsset,
    SeedTransactionMatcher
  }

  alias FullCircle.Layer.{House, Flock, Movement, Harvest, HarvestDetail}
  alias FullCircle.WeightBridge.Weighing
  alias FullCircle.Product.{Good, Packaging}

  def seed("Employees", seed_data, com, user) do
    save_seed(%Employee{}, :seed_employees, seed_data, com, user)
  end

  def seed("SalaryTypes", seed_data, com, user) do
    save_seed(%SalaryType{}, :seed_salary_types, seed_data, com, user)
  end

  def seed("EmployeeSalaryTypes", seed_data, com, user) do
    save_seed(%EmployeeSalaryType{}, :seed_employee_salary_types, seed_data, com, user, false)
  end

  def seed("TaxCodes", seed_data, com, user) do
    save_seed(%TaxCode{}, :seed_taxcodes, seed_data, com, user)
  end

  def seed("Goods", seed_data, com, user) do
    save_seed(%Good{}, :seed_goods, seed_data, com, user)
  end

  def seed("GoodPackagings", seed_data, com, user) do
    save_seed(%Packaging{}, :seed_good_packagings, seed_data, com, user)
  end

  def seed("Accounts", seed_data, com, user) do
    save_seed(%Account{}, :seed_accounts, seed_data, com, user)
  end

  def seed("Contacts", seed_data, com, user) do
    save_seed(%Contact{}, :seed_contacts, seed_data, com, user)
  end

  def seed("FixedAssets", seed_data, com, user) do
    save_seed(%FixedAsset{}, :seed_fixed_assets, seed_data, com, user)
  end

  def seed("FixedAssetDepreciations", seed_data, com, user) do
    save_seed(%FixedAssetDepreciation{}, :seed_fixed_asset_depreciations, seed_data, com, user)
  end

  def seed("Balances", seed_data, com, user) do
    save_seed(%Transaction{}, :seed_balances, seed_data, com, user, false)
  end

  def seed("Transactions", seed_data, com, user) do
    save_seed(%Transaction{}, :seed_transactions, seed_data, com, user, false)
  end

  def seed("TransactionMatchers", seed_data, com, user) do
    save_seed(%SeedTransactionMatcher{}, :seed_transaction_matchers, seed_data, com, user, false)
  end

  def seed("Houses", seed_data, com, user) do
    save_seed(%House{}, :seed_houses, seed_data, com, user)
  end

  def seed("HouseHarvestWages", seed_data, com, user) do
    save_seed(%House{}, :seed_house_harvest_wages, seed_data, com, user)
  end

  def seed("Weighings", seed_data, com, user) do
    save_seed(%Weighing{}, :seed_weighings, seed_data, com, user)
  end

  def seed("Flocks", seed_data, com, user) do
    save_seed(%Flock{}, :seed_flocks, seed_data, com, user)
  end

  def seed("Movements", seed_data, com, user) do
    save_seed(%Movement{}, :seed_movements, seed_data, com, user)
  end

  def seed("Harvests", seed_data, com, user) do
    save_seed(%Harvest{}, :seed_harvests, seed_data, com, user)
  end

  def seed("HarvestDetails", seed_data, com, user) do
    save_seed(%HarvestDetail{}, :seed_harvest_details, seed_data, com, user)
  end

  defp save_seed(_klass_struct, action, seed_data, company, user, log? \\ true) do
    case can?(user, action, company) do
      true ->
        Repo.transaction(fn repo ->
          Enum.each(seed_data, fn {cs, attr} ->
            k = repo.insert!(cs)

            if log? do
              repo.insert!(FullCircle.Sys.log_changeset(:seeding, k, attr, company, user))
            end
          end)
        end)

      false ->
        :not_authorise
    end
  rescue
    e in Ecto.InvalidChangesetError ->
      {:error, e}
  end

  defp find_txn(dt, di, ctid, comid) do
    from(txn in Transaction,
      where: txn.contact_id == ^ctid,
      where: txn.company_id == ^comid,
      where: txn.doc_type == ^dt,
      where: txn.doc_no == ^di
    )
    |> Repo.one()
  end

  defp find_1st_txn(ctid, comid) do
    from(txn in Transaction,
      where: txn.contact_id == ^ctid,
      where: txn.company_id == ^comid,
      where: txn.old_data == true,
      where: txn.closed == true,
      where: txn.doc_type == "Journal",
      where: ilike(txn.particulars, "Balance B/F%"),
      group_by: [txn.id],
      having: txn.doc_date == min(txn.doc_date)
    )
    |> Repo.one!()
  end

  def fill_changeset("TransactionMatchers", attr, com, user) do
    name = Map.fetch!(attr, "account_name")
    n_doc_type = Map.fetch!(attr, "n_doc_type")
    n_doc_id = Map.fetch!(attr, "n_doc_id")
    ct = FullCircle.Accounting.get_contact_by_name(name, com, user)

    txn_id =
      if is_nil(ct) do
        nil
      else
        try do
          (find_txn(n_doc_type, n_doc_id, ct.id, com.id) ||
             find_1st_txn(ct.id, com.id)).id
        rescue
          Ecto.NoResultsError ->
            nil

          Ecto.MultipleResultsError ->
            nil
        end
      end

    new_attr = %{
      m_doc_date: Map.fetch!(attr, "m_doc_date"),
      m_doc_type: Map.fetch!(attr, "m_doc_type"),
      m_doc_id: Map.fetch!(attr, "m_doc_id"),
      n_doc_type: Map.fetch!(attr, "n_doc_type"),
      n_doc_id: Map.fetch!(attr, "n_doc_id"),
      match_amount: Map.fetch!(attr, "m_amount"),
      transaction_id: txn_id,
      contact_name: name
    }

    {FullCircle.StdInterface.changeset(
       FullCircle.Accounting.SeedTransactionMatcher,
       FullCircle.Accounting.SeedTransactionMatcher.__struct__(),
       new_attr,
       com
     ), new_attr}
  end

  def fill_changeset("Goods", attr, com, user) do
    pur_ac =
      FullCircle.Accounting.get_account_by_name(
        Map.fetch!(attr, "purchase_account_name"),
        com,
        user
      )

    sal_ac =
      FullCircle.Accounting.get_account_by_name(
        Map.fetch!(attr, "sales_account_name"),
        com,
        user
      )

    sal_tax =
      FullCircle.Accounting.get_tax_code_by_code(
        Map.fetch!(attr, "sales_tax_code_name"),
        com,
        user
      )

    pur_tax =
      FullCircle.Accounting.get_tax_code_by_code(
        Map.fetch!(attr, "purchase_tax_code_name"),
        com,
        user
      )

    attr =
      attr
      |> Map.merge(%{"purchase_account_id" => if(pur_ac, do: pur_ac.id, else: nil)})
      |> Map.merge(%{"sales_account_id" => if(sal_ac, do: sal_ac.id, else: nil)})
      |> Map.merge(%{"purchase_tax_code_id" => if(pur_tax, do: pur_tax.id, else: nil)})
      |> Map.merge(%{"sales_tax_code_id" => if(sal_tax, do: sal_tax.id, else: nil)})

    {FullCircle.StdInterface.changeset(
       FullCircle.Product.Good,
       FullCircle.Product.Good.__struct__(),
       attr,
       com,
       :seed_changeset
     ), attr}
  end

  def fill_changeset("GoodPackagings", attr, com, user) do
    good = FullCircle.Product.get_good_by_name(Map.fetch!(attr, "good_name"), com, user)

    attr = attr |> Map.merge(%{"good_id" => good.id})

    {FullCircle.StdInterface.changeset(
       FullCircle.Product.Packaging,
       FullCircle.Product.Packaging.__struct__(),
       attr,
       com
     ), attr}
  end

  def fill_changeset("Weighings", attr, com, _user) do
    {FullCircle.StdInterface.changeset(
       FullCircle.WeightBridge.Weighing,
       FullCircle.WeightBridge.Weighing.__struct__(),
       attr,
       com,
       :seed_changeset
     ), attr}
  end

  def fill_changeset("Houses", attr, com, _user) do
    {FullCircle.StdInterface.changeset(
       FullCircle.Layer.House,
       FullCircle.Layer.House.__struct__(),
       attr,
       com
     ), attr}
  end

  def fill_changeset("HouseHarvestWages", attr, com, _user) do
    h = FullCircle.Layer.get_house_by_no(Map.fetch!(attr, "house_no"), com, nil)

    attr =
      attr
      |> Map.merge(%{"house_id" => if(h, do: h.id, else: nil)})

    {FullCircle.StdInterface.changeset(
       FullCircle.Layer.HouseHarvestWage,
       FullCircle.Layer.HouseHarvestWage.__struct__(),
       attr,
       com
     ), attr}
  end

  def fill_changeset("Flocks", attr, com, _user) do
    {FullCircle.StdInterface.changeset(
       FullCircle.Layer.Flock,
       FullCircle.Layer.Flock.__struct__(),
       attr,
       com
     ), attr}
  end

  def fill_changeset("Harvests", attr, com, user) do
    e = FullCircle.HR.get_employee_by_name(Map.fetch!(attr, "employee_name"), com, user)

    attr =
      attr
      |> Map.merge(%{"employee_id" => if(e, do: e.id, else: nil)})

    {FullCircle.StdInterface.changeset(
       FullCircle.Layer.Harvest,
       FullCircle.Layer.Harvest.__struct__(),
       attr,
       com,
       :seed_changeset
     ), attr}
  end

  def fill_changeset("HarvestDetails", attr, com, _user) do
    hv = FullCircle.Layer.get_harvest_by_no(Map.fetch!(attr, "harvest_no"), com, nil)
    h = FullCircle.Layer.get_house_by_no(Map.fetch!(attr, "house_no"), com, nil)
    f = FullCircle.Layer.get_flock_by_no(Map.fetch!(attr, "flock_no"), com, nil)

    attr =
      attr
      |> Map.merge(%{"house_id" => if(h, do: h.id, else: nil)})
      |> Map.merge(%{"flock_id" => if(f, do: f.id, else: nil)})
      |> Map.merge(%{"harvest_id" => if(hv, do: hv.id, else: nil)})

    {FullCircle.StdInterface.changeset(
       FullCircle.Layer.HarvestDetail,
       FullCircle.Layer.HarvestDetail.__struct__(),
       attr,
       com
     ), attr}
  end

  def fill_changeset("Movements", attr, com, _user) do
    h = FullCircle.Layer.get_house_by_no(Map.fetch!(attr, "house_no"), com, nil)
    f = FullCircle.Layer.get_flock_by_no(Map.fetch!(attr, "flock_no"), com, nil)

    attr =
      attr
      |> Map.merge(%{"house_id" => if(h, do: h.id, else: nil)})
      |> Map.merge(%{"flock_id" => if(f, do: f.id, else: nil)})

    {FullCircle.StdInterface.changeset(
       FullCircle.Layer.Movement,
       FullCircle.Layer.Movement.__struct__(),
       attr,
       com
     ), attr}
  end

  def fill_changeset("TaxCodes", attr, com, user) do
    account =
      FullCircle.Accounting.get_account_by_name(
        Map.fetch!(attr, "account_name"),
        com,
        user
      )

    attr = attr |> Map.merge(%{"account_id" => if(account, do: account.id, else: nil)})

    {FullCircle.StdInterface.changeset(
       FullCircle.Accounting.TaxCode,
       FullCircle.Accounting.TaxCode.__struct__(),
       attr,
       com
     ), attr}
  end

  def fill_changeset("Contacts", attr, com, _user) do
    {FullCircle.StdInterface.changeset(
       FullCircle.Accounting.Contact,
       FullCircle.Accounting.Contact.__struct__(),
       attr,
       com
     ), attr}
  end

  def fill_changeset("Accounts", attr, com, _user) do
    {FullCircle.StdInterface.changeset(
       FullCircle.Accounting.Account,
       FullCircle.Accounting.Account.__struct__(),
       attr,
       com
     ), attr}
  end

  def fill_changeset("Employees", attr, com, _user) do
    {FullCircle.StdInterface.changeset(
       FullCircle.HR.Employee,
       FullCircle.HR.Employee.__struct__(),
       attr,
       com
     ), attr}
  end

  def fill_changeset("SalaryTypes", attr, com, user) do
    db_ac =
      FullCircle.Accounting.get_account_by_name(
        Map.fetch!(attr, "db_ac_name"),
        com,
        user
      )

    cr_ac =
      FullCircle.Accounting.get_account_by_name(
        Map.fetch!(attr, "cr_ac_name"),
        com,
        user
      )

    attr =
      attr
      |> Map.merge(%{"db_ac_id" => if(db_ac, do: db_ac.id, else: nil)})
      |> Map.merge(%{"cr_ac_id" => if(cr_ac, do: cr_ac.id, else: nil)})

    {FullCircle.StdInterface.changeset(
       FullCircle.HR.SalaryType,
       FullCircle.HR.SalaryType.__struct__(),
       attr,
       com
     ), attr}
  end

  def fill_changeset("EmployeeSalaryTypes", attr, com, user) do
    emp =
      FullCircle.StdInterface.get_one_by(
        Employee,
        :name,
        Map.fetch!(attr, "employee_name"),
        com,
        user
      )

    st =
      FullCircle.StdInterface.get_one_by(
        SalaryType,
        :name,
        Map.fetch!(attr, "salary_type_name"),
        com,
        user
      )

    attr =
      attr
      |> Map.merge(%{"employee_id" => if(emp, do: emp.id, else: nil)})
      |> Map.merge(%{"salary_type_id" => if(st, do: st.id, else: nil)})
      |> Map.merge(%{"_persistent_id" => 1})

    {FullCircle.StdInterface.changeset(
       FullCircle.HR.EmployeeSalaryType,
       FullCircle.HR.EmployeeSalaryType.__struct__(),
       attr,
       com
     ), attr}
  end

  def fill_changeset("FixedAssets", attr, com, user) do
    asset_ac =
      FullCircle.Accounting.get_account_by_name(
        Map.fetch!(attr, "asset_ac_name"),
        com,
        user
      )

    dep_ac =
      FullCircle.Accounting.get_account_by_name(
        Map.fetch!(attr, "depre_ac_name"),
        com,
        user
      )

    dis_ac =
      FullCircle.Accounting.get_account_by_name(
        Map.fetch!(attr, "disp_fund_ac_name"),
        com,
        user
      )

    cume_depre_ac =
      FullCircle.Accounting.get_account_by_name(
        Map.fetch!(attr, "cume_depre_ac_name"),
        com,
        user
      )

    attr =
      attr
      |> Map.merge(%{"asset_ac_id" => if(asset_ac, do: asset_ac.id, else: nil)})
      |> Map.merge(%{"depre_ac_id" => if(dep_ac, do: dep_ac.id, else: nil)})
      |> Map.merge(%{"disp_fund_ac_id" => if(dis_ac, do: dis_ac.id, else: nil)})
      |> Map.merge(%{"cume_depre_ac_id" => if(cume_depre_ac, do: cume_depre_ac.id, else: nil)})

    {FullCircle.StdInterface.changeset(
       FullCircle.Accounting.FixedAsset,
       FullCircle.Accounting.FixedAsset.__struct__(),
       attr,
       com
     ), attr}
  end

  def fill_changeset("FixedAssetDepreciations", attr, com, user) do
    fa =
      FullCircle.Accounting.get_fixed_asset_by_name(
        Map.fetch!(attr, "fixed_asset_name"),
        com,
        user
      )

    attr =
      attr
      |> Map.merge(%{"is_seed" => true})
      |> Map.merge(%{"fixed_asset_id" => if(fa, do: fa.id, else: nil)})
      |> Map.merge(%{"doc_no" => FullCircle.Helpers.gen_temp_id(10)})

    {FullCircle.StdInterface.changeset(
       FullCircle.Accounting.FixedAssetDepreciation,
       FullCircle.Accounting.FixedAssetDepreciation.__struct__(),
       attr,
       com
     ), attr}
  end

  def fill_changeset("Balances", attr, com, user) do
    name = Map.fetch!(attr, "account_name")

    attr =
      attr
      |> Map.merge(%{
        "old_data" => "true",
        "closed" => "true",
        "doc_no" => FullCircle.Helpers.gen_temp_id(10),
        "doc_type" => "Journal"
      })

    {ac, ct} =
      get_ac_from_fixed_asset(name, com) ||
        get_ac_form_attr(attr, com, user)

    attr = if(ac, do: Map.merge(attr, %{"account_id" => ac.id}), else: attr)
    attr = if(ct, do: Map.merge(attr, %{"contact_id" => ct.id}), else: attr)

    ac_name = if(name != ac.name, do: "#{ac.name} (#{name})", else: ac.name)

    attr =
      attr
      |> Map.merge(%{
        "particulars" => if(ct, do: "Balance B/F #{ct.name}", else: "Balance B/F #{ac_name}")
      })

    {FullCircle.StdInterface.changeset(
       FullCircle.Accounting.Transaction,
       FullCircle.Accounting.Transaction.__struct__(),
       attr,
       com
     ), attr}
  end

  def fill_changeset("Transactions", attr, com, user) do
    name = Map.fetch!(attr, "account_name")

    {ac, ct} =
      get_ac_from_fixed_asset(name, com) ||
        get_ac_form_attr(attr, com, user)

    attr = if(ac, do: Map.merge(attr, %{"account_id" => ac.id}), else: attr)
    attr = if(ct, do: Map.merge(attr, %{"contact_id" => ct.id}), else: attr)

    ac_name = if(name != ac.name, do: "#{ac.name} (#{name})", else: ac.name)
    part = attr["particulars"]

    attr =
      attr
      |> Map.merge(%{
        "particulars" => ac_name,
        "contact_particulars" => part
      })

    attr =
      attr
      |> Map.merge(%{"closed" => "true"})
      |> Map.merge(%{"old_data" => "true"})

    {FullCircle.StdInterface.changeset(
       FullCircle.Accounting.Transaction,
       FullCircle.Accounting.Transaction.__struct__(),
       attr,
       com
     ), attr}
  end

  def get_ac_from_fixed_asset(name, com) do
    Repo.one(
      from fa in FixedAsset,
        join: ac in Account,
        on: ac.id == fa.asset_ac_id,
        where: fragment("? like ?", fa.name, ^"#{name}%"),
        where: fa.company_id == ^com.id,
        distinct: true,
        select: {ac, nil}
    )
  end

  def get_ac_form_attr(attr, com, user) do
    name = Map.fetch!(attr, "account_name")
    ac = FullCircle.Accounting.get_account_by_name(name, com, user)
    ct = FullCircle.Accounting.get_contact_by_name(name, com, user)

    if is_nil(ac) do
      ac_rec = FullCircle.Accounting.get_account_by_name("Account Receivables", com, user)
      ac_pay = FullCircle.Accounting.get_account_by_name("Account Payables", com, user)
      doc_type = Map.fetch!(attr, "doc_type")

      ac =
        case doc_type do
          "Invoice" ->
            ac_rec

          "PurInvoice" ->
            ac_pay

          "Payment" ->
            ac_pay

          "Receipt" ->
            ac_rec

          "CreditNote" ->
            ac_rec

          "DebitNote" ->
            ac_pay

          "ReturnCheque" ->
            ac_rec

          "Journal" ->
            if Map.fetch!(attr, "amount") |> Decimal.new() |> Decimal.to_float() > 0 do
              ac_rec
            else
              ac_pay
            end

          _ ->
            nil
        end

      {ac, ct}
    else
      {ac, ct}
    end
  end

  def get_transactions(doc_type, doc_no, com_id) do
    from(txn in Transaction,
      join: ac in Account,
      on: ac.id == txn.account_id,
      left_join: cont in Contact,
      on: cont.id == txn.contact_id,
      where: txn.doc_type == ^doc_type,
      where: txn.doc_no == ^doc_no,
      where: txn.company_id == ^com_id,
      where: txn.old_data == true,
      select: txn,
      select_merge: %{
        account_name: ac.name,
        contact_name: cont.name
      }
    )
    |> FullCircle.Repo.all()
  end
end
