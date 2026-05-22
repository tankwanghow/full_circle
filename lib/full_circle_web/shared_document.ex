defmodule FullCircleWeb.SharedDocument do
  @moduledoc """
  Signed, time-limited tokens for the public "view this document" links, plus
  the LiveView `on_mount` hook that authenticates the public print routes from
  such a token instead of a logged-in session.
  """

  @salt "shared document"
  # 30 days, in seconds.
  @max_age 2_592_000

  @doc "Signs a stateless token carrying the document type, id, company id and sending user id."
  def sign(doc_type, doc_id, company_id, user_id) do
    Phoenix.Token.sign(FullCircleWeb.Endpoint, @salt, %{
      t: doc_type,
      d: doc_id,
      c: company_id,
      u: user_id
    })
  end

  @doc "Verifies a token. Returns {:ok, payload} or {:error, :expired | :invalid | term()}."
  def verify(token) when is_binary(token) do
    Phoenix.Token.verify(FullCircleWeb.Endpoint, @salt, token, max_age: @max_age)
  end

  def verify(_), do: {:error, :invalid}
end
