defmodule FullCircle.Seeding do
  import Ecto.Query, warn: false
  import FullCircle.Authorization

  alias FullCircle.Repo
  alias FullCircle.Sys.{Log}
  alias FullCircle.Accounting.{TaxCode}
  alias FullCircle.Product.{Good}

  def seed("TaxCodes", seed_data, company, user) do
    case can?(user, :seed_taxcodes, company) do
      true ->
        Repo.transaction(fn repo ->
          Enum.map(seed_data, fn x ->
            {:ok, k} = repo.insert(x)

            repo.insert(
              Log.changeset(%Log{}, %{
                entity: %TaxCode{}.__meta__.source,
                entity_id: k.id,
                action: "seeding",
                delta: "N/A",
                user_id: user.id,
                company_id: company.id
              })
            )
            k
          end)

        end)
        |> case do
          {:ok, _} ->
            :ok

          {:error, _} ->
            :error
        end

      false ->
        :not_authorise
    end
  end

  def seed("Goods", seed_data, company, user) do
    case can?(user, :seed_goods, company) do
      true ->
        Repo.transaction(fn repo ->
          Enum.map(seed_data, fn x ->
            {:ok, k} = repo.insert(x)

            repo.insert(
              Log.changeset(%Log{}, %{
                entity: %Good{}.__meta__.source,
                entity_id: k.id,
                action: "seeding",
                delta: "N/A",
                user_id: user.id,
                company_id: company.id
              })
            )
            k
          end)

        end)
        |> case do
          {:ok, _} ->
            :ok

          {:error, _} ->
            :error
        end

      false ->
        :not_authorise
    end
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
end
