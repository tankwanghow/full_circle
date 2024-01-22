defmodule FullCircleWeb.BillingTagController do
  use FullCircleWeb, :controller

  def index(conn, params) do
    tag = params["tag"]
    tag_field = (params["tag_field"] || "tags") |> String.to_atom()
    tags = FullCircle.Helpers.list_billing_tags(tag, tag_field, %{id: params["company_id"]})
    render(conn, :index, %{tags: tags})
  end
end
