defmodule FullCircleWeb.TagController do
  use FullCircleWeb, :controller

  def index(conn, params) do
    tag_field = (params["tag_field"] || "tags") |> String.to_atom()
    tag = params["tag"]
    {klass, _} = Code.eval_string(params["klass"])
    tags = FullCircle.Helpers.list_klass_tags(tag, klass, tag_field, %{id: params["company_id"]})
    render(conn, :index, %{tags: tags})
  end
end
