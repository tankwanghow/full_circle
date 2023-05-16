alias FullCircle.StdInterface
import Ecto.Query, warn: false

alias FullCircle.Repo

good_data =
  File.stream!("/home/tankwanghow/Projects/elixir/full_circle/priv/repo/goods.csv")
  |> NimbleCSV.RFC4180.parse_stream()
  |> Stream.map(fn [name, desc, unit] ->
    %{name: name, descriptions: desc, unit: unit}
  end)
  |> Enum.to_list()

alias FullCircle.Product.Good
alias FullCircle.Accounting.TaxCode

pac =
  Repo.get_by!(
    FullCircle.Accounting.Account,
    name: "General Purchase"
  )

sac =
  Repo.get_by!(
    FullCircle.Accounting.Account,
    name: "General Sales"
  )

stc =
  Repo.get_by!(
    TaxCode,
    code: "SR"
  )

ptc =
  Repo.get_by!(
    TaxCode,
    code: "TX"
  )

Enum.each(good_data, fn data ->
  data =
    Map.merge(data, %{
      purchase_account_id: pac.id,
      purchase_account_name: pac.name,
      sales_account_id: sac.id,
      sales_account_name: sac.name,
      purchase_tax_code_id: ptc.id,
      sales_tax_code_id: stc.id,
      purchase_tax_code_name: ptc.code,
      sales_tax_code_name: stc.code,
      packagings: %{"0" => %{name: "-", unit_multiplier: 0, cost_per_package: 0}}
    })

  StdInterface.create(Good, "good", data, %{id: 1}, %{id: 1})
end)
