defmodule FullCircleWeb.PhoneUpload do
  @moduledoc """
  The "📱 From phone" link: a signed token naming one write-box tray or one
  saved note, its company and the desktop user. It authorises uploads into
  that one target only — never reads. Idle expiry is 600s: every successful
  upload hands the phone a fresh token. Every request re-checks that the user
  is still active in the company (and, for a note, may still edit it — the
  upload functions do that). Each QR is one session (`s`, carried by the
  refreshed tokens too); "✓ Finished" on the phone ends it at once
  (`finish/1`, `PhoneUploadFinished`).
  """
  alias FullCircle.{Repo, Sys}
  alias FullCircle.Notes.Note
  alias FullCircle.Sys.{Company, CompanyUser}
  alias FullCircle.UserAccounts.User

  @salt "note phone upload"
  @max_age 600

  def max_age, do: @max_age

  def sign({kind, id}, label, company_id, user_id, session \\ Ecto.UUID.generate())
      when kind in [:tray, :note] do
    Phoenix.Token.sign(FullCircleWeb.Endpoint, @salt, %{
      t: Atom.to_string(kind),
      i: id,
      c: company_id,
      u: user_id,
      l: label,
      s: session
    })
  end

  @doc "Ends the token's session (\"✓ Finished\" on the phone): every token of it stops working."
  def finish(token) do
    case verify(token) do
      {:ok, %{s: session}} -> FullCircleWeb.PhoneUploadFinished.put(session, @max_age)
      _ -> :ok
    end
  end

  defp verify(token),
    do: Phoenix.Token.verify(FullCircleWeb.Endpoint, @salt, token, max_age: @max_age)

  def url(target, label, company, user),
    do: FullCircleWeb.Endpoint.url() <> "/up/" <> sign(target, label, company.id, user.id)

  def resolve(token) when is_binary(token) do
    with {:ok, %{t: t, i: id, c: cid, u: uid, l: label, s: session}} <- verify(token),
         false <- FullCircleWeb.PhoneUploadFinished.finished?(session),
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
         token: sign({kind, id}, label, cid, uid, session)
       }}
    else
      {:error, :expired} -> {:error, :expired}
      # The session was ended with "✓ Finished".
      true -> {:error, :expired}
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
