defmodule FullCircleWeb.PhoneUploadTest do
  use FullCircle.DataCase

  import FullCircle.BillingFixtures
  import FullCircle.NotesFixtures

  alias FullCircleWeb.PhoneUpload

  setup do
    billing_setup()
  end

  test "resolves a fresh token to its target, company and user", %{admin: a, company: c} do
    tray_id = Ecto.UUID.generate()
    token = PhoneUpload.sign({:tray, tray_id}, "a new note", c.id, a.id)

    assert {:ok,
            %{target: {:tray, ^tray_id}, label: "a new note", company: co, user: u, token: t2}} =
             PhoneUpload.resolve(token)

    assert co.id == c.id and u.id == a.id
    assert {:ok, _} = PhoneUpload.resolve(t2)
  end

  test "an expired token is refused", %{admin: a, company: c} do
    old =
      Phoenix.Token.sign(
        FullCircleWeb.Endpoint,
        "note phone upload",
        %{t: "note", i: Ecto.UUID.generate(), c: c.id, u: a.id, l: "x"},
        signed_at: System.system_time(:second) - PhoneUpload.max_age() - 1
      )

    assert {:error, :expired} = PhoneUpload.resolve(old)
  end

  test "garbage and a forged target kind are invalid", %{admin: a, company: c} do
    assert {:error, :invalid} = PhoneUpload.resolve("nope")
    assert {:error, :invalid} = PhoneUpload.resolve(nil)

    forged =
      Phoenix.Token.sign(FullCircleWeb.Endpoint, "note phone upload", %{
        t: "company",
        i: c.id,
        c: c.id,
        u: a.id,
        l: "x"
      })

    assert {:error, :invalid} = PhoneUpload.resolve(forged)
  end

  test "a user disabled after the QR was shown is refused", %{admin: a, company: c} do
    clerk = user_with_role(c, a, "clerk")
    token = PhoneUpload.sign({:tray, Ecto.UUID.generate()}, "x", c.id, clerk.id)

    Repo.update_all(
      from(cu in FullCircle.Sys.CompanyUser,
        where: cu.company_id == ^c.id and cu.user_id == ^clerk.id
      ),
      set: [role: "disable"]
    )

    assert {:error, :no_access} = PhoneUpload.resolve(token)
  end

  test "url is absolute and note_label prefers the title" do
    assert PhoneUpload.url({:note, "n"}, "x", %{id: "c"}, %{id: "u"}) =~ ~r{^https?://.+/up/.+}

    assert PhoneUpload.note_label(%FullCircle.Notes.Note{title: "Bank letter", body: "b"}) ==
             "Bank letter"

    assert PhoneUpload.note_label(%FullCircle.Notes.Note{
             title: nil,
             body: String.duplicate("x", 60)
           }) == String.duplicate("x", 40) <> "…"
  end

  test "finishing a session ends its tokens at once, refreshed ones too", %{admin: a, company: c} do
    token = PhoneUpload.sign({:tray, Ecto.UUID.generate()}, "x", c.id, a.id)
    {:ok, %{token: refreshed}} = PhoneUpload.resolve(token)

    assert :ok = PhoneUpload.finish(refreshed)
    assert {:error, :expired} = PhoneUpload.resolve(token)
    assert {:error, :expired} = PhoneUpload.resolve(refreshed)

    other = PhoneUpload.sign({:tray, Ecto.UUID.generate()}, "x", c.id, a.id)
    assert {:ok, _} = PhoneUpload.resolve(other)
  end
end
