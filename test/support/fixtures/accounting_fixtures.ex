defmodule FullCircle.AccountingFixtures do
  def unique_account_name, do: "account#{System.unique_integer()}"

  def valid_account_attributes(attrs \\ %{}) do
    actype =
      FullCircle.Accounting.account_types()
      |> Enum.at((FullCircle.Accounting.account_types() |> Enum.count() |> :rand.uniform()) - 1)

    Enum.into(attrs, %{
      name: unique_account_name(),
      account_type: actype,
      descriptions: "some descriptions"
    })
  end

  def account_fixture(attrs, company, user) do
    attrs = attrs |> valid_account_attributes()

    {:ok, account} =
      FullCircle.StdInterface.create(
        FullCircle.Accounting.Account,
        "account",
        attrs,
        company,
        user
      )

    account
  end
end
