defmodule FullCircle.SysFixtures do
  def unique_company_name, do: "company#{System.unique_integer()}"

  def valid_company_attributes(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})

    # The day has to be drawn from the month that actually ends up in the attrs,
    # or the pair can be one the app rejects — the closing_day select is built
    # per month, so e.g. February + day 30 is not offered anywhere in the UI.
    closing_month = Map.get(attrs, :closing_month, :rand.uniform(12))

    Map.merge(
      %{
        name: unique_company_name(),
        address1: "some address1",
        address2: "some address2",
        city: "some city",
        country: "Malaysia",
        state: "some state",
        zipcode: "some zipcode",
        closing_month: closing_month,
        closing_day: :rand.uniform(days_in_closing_month(closing_month)),
        reg_no: "some reg_no",
        tax_id: "some tax_id",
        descriptions: "some descriptions",
        timezone: "Asia/Kuala_Lumpur",
        email: "some email",
        tel: "some tel",
        fax: "some fax"
      },
      attrs
    )
  end

  defdelegate days_in_closing_month(month), to: FullCircle.Sys.Company

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
