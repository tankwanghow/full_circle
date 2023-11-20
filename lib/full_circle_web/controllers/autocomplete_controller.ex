defmodule FullCircleWeb.AutoCompleteController do
  use FullCircleWeb, :controller

  def index(conn, params) do
    schema = params["schema"]
    name = params["name"] |> String.codepoints() |> Enum.join("%")

    names =
      case schema do
        "house" ->
          FullCircle.Layer.houses_no(name, %{id: params["company_id"]}, %{
            id: params["user_id"]
          })

        "contact" ->
          FullCircle.Accounting.contact_names(
            name,
            %{id: params["company_id"]},
            %{id: params["user_id"]}
          )

        "good" ->
          FullCircle.Product.good_names(name, %{id: params["company_id"]}, %{
            id: params["user_id"]
          })

        "account" ->
          FullCircle.Accounting.account_names(
            name,
            %{id: params["company_id"]},
            %{id: params["user_id"]}
          )

        "fundsaccount" ->
          FullCircle.Accounting.funds_account_names(
            name,
            %{id: params["company_id"]},
            %{id: params["user_id"]}
          )

        "packaging" ->
          if params["good_id"] == "" do
            []
          else
            FullCircle.Product.package_names(name, params["good_id"])
          end

        "saltaxcode" ->
          FullCircle.Accounting.sale_tax_codes(
            name,
            %{id: params["company_id"]},
            %{id: params["user_id"]}
          )

        "purtaxcode" ->
          FullCircle.Accounting.purchase_tax_codes(
            name,
            %{id: params["company_id"]},
            %{id: params["user_id"]}
          )

        "taxcode" ->
          FullCircle.Accounting.tax_codes(
            name,
            %{id: params["company_id"]},
            %{id: params["user_id"]}
          )

        "salarytype" ->
          FullCircle.HR.salary_types(
            name,
            %{id: params["company_id"]},
            %{id: params["user_id"]}
          )

        "employee" ->
          FullCircle.HR.employees(
            name,
            %{id: params["company_id"]},
            %{id: params["user_id"]}
          )

        _ ->
          []
      end

    render(conn, :index, values: names)
  end
end
