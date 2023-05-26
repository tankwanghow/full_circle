defmodule FullCircle.Product do
  import Ecto.Query, warn: false
  import FullCircle.Helpers

  alias FullCircle.Accounting.{Account, TaxCode}
  alias FullCircle.Product.{Good, Packaging}
  alias FullCircle.{Repo, Sys}

  def get_good!(id, user, company) do
    from(good in subquery(good_query(user, company)),
      preload: :packagings,
      where: good.id == ^id
    )
    |> Repo.one!()
  end

  def good_names(terms, user, company) do
    from(good in subquery(good_query(user, company)),
      left_join: pack in Packaging,
      on: pack.good_id == good.id,
      where: ilike(good.name, ^"%#{terms}%"),
      select: %{
        id: good.id,
        value: good.name,
        unit: good.unit,
        package_name: pack.name,
        package_id: pack.id,
        unit_multiplier: pack.unit_multiplier,
        sales_account_name: good.sales_account_name,
        purchase_account_name: good.purchase_account_name,
        sales_account_id: good.sales_account_id,
        purchase_account_id: good.purchase_account_id,
        sales_tax_code_name: good.sales_tax_code_name,
        purchase_tax_code_name: good.purchase_tax_code_name,
        sales_tax_code_id: good.sales_tax_code_id,
        purchase_tax_code_id: good.purchase_tax_code_id,
        sales_tax_rate: good.sales_tax_rate,
        purchase_tax_rate: good.purchase_tax_rate
      },
      order_by: [good.name, pack.id],
      distinct: good.name
    )
    |> Repo.all()
  end

  def package_names(terms, good_id) do
    from(pack in Packaging,
      where: ilike(pack.name, ^"%#{terms}%"),
      where: pack.good_id == ^good_id,
      select: %{
        id: pack.id,
        value: pack.name,
        unit_multiplier: pack.unit_multiplier
      }
    )
    |> Repo.all()
  end

  defp good_query(user, company) do
    from(good in Good,
      join: com in subquery(Sys.user_company(company, user)),
      on: com.id == good.company_id,
      left_join: sac in Account,
      on: sac.id == good.sales_account_id,
      left_join: pac in Account,
      on: pac.id == good.purchase_account_id,
      left_join: stc in TaxCode,
      on: stc.id == good.sales_tax_code_id,
      left_join: ptc in TaxCode,
      on: ptc.id == good.purchase_tax_code_id,
      select: %Good{
        id: good.id,
        name: good.name,
        unit: good.unit,
        sales_account_name: sac.name,
        purchase_account_name: pac.name,
        sales_account_id: sac.id,
        purchase_account_id: pac.id,
        sales_tax_code_name: stc.code,
        purchase_tax_code_name: ptc.code,
        sales_tax_code_id: stc.id,
        purchase_tax_code_id: ptc.id,
        sales_tax_rate: stc.rate,
        purchase_tax_rate: ptc.rate,
        descriptions: good.descriptions,
        inserted_at: good.inserted_at,
        updated_at: good.updated_at
      }
    )
  end

  def good_index_query("", user, company, page: page, per_page: per_page) do
    from(good in subquery(good_query(user, company)),
      offset: ^((page - 1) * per_page),
      limit: ^per_page,
      preload: :packagings,
      order_by: [desc: good.updated_at]
    )
    |> Repo.all()
  end

  def good_index_query(terms, user, company, page: page, per_page: per_page) do
    from(good in subquery(good_query(user, company)),
      offset: ^((page - 1) * per_page),
      limit: ^per_page,
      preload: :packagings,
      order_by:
        ^similarity_order(
          ~w(name unit purchase_account_name sales_account_name sales_tax_code_name purchase_tax_code_name descriptions)a,
          terms
        )
    )
    |> Repo.all()
  end
end
