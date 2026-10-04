defmodule FullCircleWeb.PhoneUpload do
  @moduledoc """
  The "📱 From phone" link: a signed token naming one write-box tray or one
  saved note, its company and the desktop user. It authorises uploads into
  that one target only — never reads. Idle expiry is 600s: every successful
  upload hands the phone a fresh token. Every request re-checks that the user
  is still active in the company (and, for a note, may still edit it — the
  upload functions do that).
  """
  alias FullCircle.{Repo, Sys}
  alias FullCircle.Notes.Note
  alias FullCircle.Sys.{Company, CompanyUser}
  alias FullCircle.UserAccounts.User

  @salt "note phone upload"
  @max_age 600

  def max_age, do: @max_age

  def sign({kind, id}, label, company_id, user_id) when kind in [:tray, :note] do
    Phoenix.Token.sign(FullCircleWeb.Endpoint, @salt, %{
      t: Atom.to_string(kind),
      i: id,
      c: company_id,
      u: user_id,
      l: label
    })
  end

  def url(target, label, company, user),
    do: FullCircleWeb.Endpoint.url() <> "/up/" <> sign(target, label, company.id, user.id)

  def resolve(token) when is_binary(token) do
    with {:ok, %{t: t, i: id, c: cid, u: uid, l: label}} <-
           Phoenix.Token.verify(FullCircleWeb.Endpoint, @salt, token, max_age: @max_age),
         {:ok, kind} <- kind(t),
         %Company{} = company <- Repo.get(Company, cid),
         %User{} = user <- Repo.get(User, uid),
         %CompanyUser{role: role} when role != "disable" <- Sys.get_company_user(cid, uid) do
      {:ok,
       %{
         target: {kind, id},
         label: label,
         company: company,
         user: user,
         token: sign({kind, id}, label, cid, uid)
       }}
    else
      {:error, :expired} -> {:error, :expired}
      %CompanyUser{} -> {:error, :no_access}
      _ -> {:error, :invalid}
    end
  end

  def resolve(_), do: {:error, :invalid}

  def note_label(%Note{title: title}) when is_binary(title) and title != "", do: title

  def note_label(%Note{body: body}) do
    body = String.trim(body || "")
    if String.length(body) > 40, do: String.slice(body, 0, 40) <> "…", else: body
  end

  defp kind("tray"), do: {:ok, :tray}
  defp kind("note"), do: {:ok, :note}
  defp kind(_), do: :error
end
