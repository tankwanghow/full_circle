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

  defp good_query(user, company) do
    from(good in Good,
      join: com in subquery(Sys.user_companies(company, user)),
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
        sales_tax_code: stc.code,
        purchase_tax_code: ptc.code,
        sales_tax_code_id: stc.id,
        purchase_tax_code_id: ptc.id,
        descriptions: good.descriptions,
        inserted_at: good.inserted_at,
        updated_at: good.updated_at
      }
    )
  end

  def good_index_query(terms, user, company, page: page, per_page: per_page) do
    from(good in subquery(good_query(user, company)),
      offset: ^((page - 1) * per_page),
      limit: ^per_page,
      preload: :packagings,
      order_by:
        ^similarity_order(
          ~w(name unit purchase_account_name sales_account_name sales_tax_code purchase_tax_code descriptions)a,
          terms
        )
    )
    |> Repo.all()
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
end
