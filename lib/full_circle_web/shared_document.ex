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

  @doc """
  on_mount hook for the public document routes. Verifies `params["token"]`,
  confirms it matches the route's `doc_type` and the `:id` in the path, then
  assigns `current_user`, `current_company` and `shared_view?: true` so the
  existing print LiveViews render unchanged. Any failure redirects to
  `/shared/expired`.
  """
  def on_mount({:verify_token, doc_type}, params, _session, socket) do
    with token when is_binary(token) <- params["token"],
         {:ok, %{t: ^doc_type, d: doc_id, c: company_id, u: user_id}} <- verify(token),
         true <- doc_id == params["id"],
         company when not is_nil(company) <-
           FullCircle.Repo.get(FullCircle.Sys.Company, company_id),
         user when not is_nil(user) <-
           FullCircle.Repo.get(FullCircle.UserAccounts.User, user_id) do
      {:cont,
       socket
       |> Phoenix.Component.assign(:current_company, company)
       |> Phoenix.Component.assign(:current_user, user)
       |> Phoenix.Component.assign(:shared_view?, true)}
    else
      _ -> {:halt, Phoenix.LiveView.redirect(socket, to: "/shared/expired")}
    end
  end
end
