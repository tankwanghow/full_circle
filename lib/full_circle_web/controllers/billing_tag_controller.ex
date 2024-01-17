defmodule FullCircleWeb.BillingTagController do
  use FullCircleWeb, :controller

  def index(conn, params) do
    tag = params["tag"]
    l_tags = FullCircle.Helpers.list_billing_tags(tag, :loader_tags, %{id: params["company_id"]})
    u_tags = FullCircle.Helpers.list_billing_tags(tag, :delivery_man_tags, %{id: params["company_id"]})
    tags = Enum.concat(l_tags, u_tags) |> Enum.uniq()
    render(conn, :index, %{tags: tags})
  end
end
