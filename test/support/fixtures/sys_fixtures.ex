defmodule FullCircle.SysFixtures do
  def unique_company_name, do: "company#{System.unique_integer()}"

  def valid_company_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      name: unique_company_name(),
      address1: "some address1",
      address2: "some address2",
      city: "some city",
      country: "Malaysia",
      state: "some state",
      zipcode: "some zipcode",
      closing_month: :rand.uniform(12),
      closing_day: :rand.uniform(30),
      reg_no: "some reg_no",
      tax_id: "some tax_id",
      descriptions: "some descriptions",
      timezone: "Asia/Kuala_Lumpur",
      email: "some email",
      tel: "some tel",
      fax: "some fax"
    })
  end

  def company_fixture(attrs \\ %{}),
    do: company_fixture(FullCircle.UserAccountsFixtures.user_fixture(), attrs)

  def company_fixture(user, attrs) do
    {:ok, company} =
      attrs
      |> valid_company_attributes()
      |> FullCircle.Sys.create_company(user)

    company
  end
end
