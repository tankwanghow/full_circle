defmodule FullCircle.Seeding do
  import Ecto.Query, warn: false
  import FullCircle.Authorization

  alias FullCircle.Repo
  alias FullCircle.Sys.{Log}
  alias FullCircle.Accounting.{TaxCode, Account, Contact, Transaction, FixedAsset}
  alias FullCircle.Product.{Good}

  def seed("TaxCodes", seed_data, com, user) do
    save_seed(%TaxCode{}, :seed_taxcodes, seed_data, com, user)
  end

  def seed("Goods", seed_data, com, user) do
    save_seed(%Good{}, :seed_goods, seed_data, com, user)
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

  def seed("Transactions", seed_data, com, user) do
    save_seed(%Transaction{}, :seed_transactions, seed_data, com, user)
  end

  defp save_seed(klass_struct, action, seed_data, company, user) do
    case can?(user, action, company) do
      true ->
        Repo.transaction(fn repo ->
          Enum.each(seed_data, fn x ->
            k = repo.insert!(x)

            repo.insert(
              Log.changeset(%Log{}, %{
                entity: klass_struct.__meta__.source,
                entity_id: k.id,
                action: "seeding",
                delta: "N/A",
                user_id: user.id,
                company_id: company.id
              })
            )
          end)
        end)

      false ->
        :not_authorise
    end
  rescue
    e in Ecto.InvalidChangesetError ->
      {:error, e}
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
      |> Map.merge(%{packagings: %{"0" => %{name: "-", unit_multiplier: 0, cost_per_package: 0}}})

    FullCircle.StdInterface.changeset(
      FullCircle.Product.Good,
      FullCircle.Product.Good.__struct__(),
      attr,
      com
    )
  end

  def fill_changeset("TaxCodes", attr, com, user) do
    account =
      FullCircle.Accounting.get_account_by_name(
        Map.fetch!(attr, "account_name"),
        com,
        user
      )

    attr = attr |> Map.merge(%{"account_id" => if(account, do: account.id, else: nil)})

    FullCircle.StdInterface.changeset(
      FullCircle.Accounting.TaxCode,
      FullCircle.Accounting.TaxCode.__struct__(),
      attr,
      com
    )
  end

  def fill_changeset("Contacts", attr, com, _user) do
    FullCircle.StdInterface.changeset(
      FullCircle.Accounting.Contact,
      FullCircle.Accounting.Contact.__struct__(),
      attr,
      com
    )
  end

  def fill_changeset("Accounts", attr, com, _user) do
    FullCircle.StdInterface.changeset(
      FullCircle.Accounting.Account,
      FullCircle.Accounting.Account.__struct__(),
      attr,
      com
    )
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

    attr =
      attr
      |> Map.merge(%{"asset_ac_id" => if(asset_ac, do: asset_ac.id, else: nil)})
      |> Map.merge(%{"depre_ac_id" => if(dep_ac, do: dep_ac.id, else: nil)})
      |> Map.merge(%{"disp_fund_ac_id" => if(dis_ac, do: dis_ac.id, else: nil)})

    FullCircle.StdInterface.changeset(
      FullCircle.Accounting.FixedAsset,
      FullCircle.Accounting.FixedAsset.__struct__(),
      attr,
      com
    )
  end
end