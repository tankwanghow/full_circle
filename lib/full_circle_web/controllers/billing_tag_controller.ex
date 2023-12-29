defmodule FullCircleWeb.BillingTagController do
  use FullCircleWeb, :controller

  def index(conn, params) do
    tag = params["tag"]
    tags = FullCircle.Helpers.list_billing_tags(tag, :tags, %{id: params["company_id"]})
    render(conn, :index, %{tags: tags})
  end
end
