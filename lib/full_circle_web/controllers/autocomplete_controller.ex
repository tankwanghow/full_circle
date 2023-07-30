defmodule FullCircleWeb.AutoCompleteController do
  use FullCircleWeb, :controller

  def index(conn, params) do
    schema = params["schema"]
    name = params["name"]

    names =
      case schema do
        "contact" ->
          FullCircle.Accounting.contact_names(
            name,
            %{id: params["id"]},
            conn.assigns.current_user
          )

        "good" ->
          FullCircle.Product.good_names(name, %{id: params["id"]}, conn.assigns.current_user)

        "account" ->
          FullCircle.Accounting.account_names(
            name,
            %{id: params["id"]},
            conn.assigns.current_user
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
            %{id: params["id"]},
            conn.assigns.current_user
          )

        "purtaxcode" ->
          FullCircle.Accounting.purchase_tax_codes(
            name,
            %{id: params["id"]},
            conn.assigns.current_user
          )

        _ ->
          []
      end

    render(conn, :index, values: names)
  end
end
