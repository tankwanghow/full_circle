defmodule FullCircleWeb.TagController do
  use FullCircleWeb, :controller

  def index(conn, params) do
    tag = params["tag"]
    {klass, _} = Code.eval_string(params["klass"])
    tags = FullCircle.Helpers.list_hashtag(tag, klass, :tags, %{id: params["id"]})
    render(conn, :index, tags: tags)
  end
end
