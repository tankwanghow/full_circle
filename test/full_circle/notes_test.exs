defmodule FullCircle.NotesTest do
  use FullCircle.DataCase

  import FullCircle.BillingFixtures
  import FullCircle.NotesFixtures

  alias FullCircle.Notes

  setup do
    billing_setup()
  end

  describe "notes authorization" do
    test_authorise_to(:view_notes, [
      "admin",
      "manager",
      "supervisor",
      "cashier",
      "clerk",
      "auditor"
    ])

    test_authorise_to(:create_note, ["admin", "manager", "supervisor", "cashier", "clerk"])
    test_authorise_to(:edit_others_note, ["admin", "manager"])
    test_authorise_to(:delete_others_note, ["admin", "manager"])
  end

  alias FullCircle.Notes.Note

  describe "Note.changeset/2" do
    test "body is required and title is capped at 120" do
      cs = Note.changeset(%Note{}, %{"body" => "", "title" => String.duplicate("x", 121)})
      assert %{body: ["can't be blank"], title: [_]} = errors_on(cs)
    end

    test "subject type and id come as a pair" do
      cs = Note.changeset(%Note{}, %{"body" => "b", "subject_type" => "Contact"})
      assert %{subject_id: ["must be set together with subject type"]} = errors_on(cs)
    end

    test "visibility accepts known roles only, never disable" do
      cs = Note.changeset(%Note{}, %{"body" => "b", "visibility" => ["manager", "disable"]})
      assert %{visibility: ["has an invalid entry"]} = errors_on(cs)

      cs = Note.changeset(%Note{}, %{"body" => "b", "visibility" => ["manager", "clerk"]})
      assert cs.valid?
    end

    test "an empty visibility list is rejected — public is nil" do
      cs = Note.changeset(%Note{}, %{"body" => "b", "visibility" => []})
      assert %{visibility: ["use nil for public"]} = errors_on(cs)
    end

    test "display_title falls back to the first body line" do
      assert Note.display_title(%Note{title: nil, body: "first line\nsecond"}) == "first line"
      assert Note.display_title(%Note{title: "T", body: "x"}) == "T"
    end
  end

  describe "visibility" do
    setup %{admin: admin, company: company} do
      %{
        manager: user_with_role(company, admin, "manager"),
        clerk: user_with_role(company, admin, "clerk"),
        clerk2: user_with_role(company, admin, "clerk"),
        auditor: user_with_role(company, admin, "auditor"),
        guest: user_with_role(company, admin, "guest")
      }
    end

    test "public note is read by every role with view_notes", ctx do
      note = note_fixture(ctx.company, ctx.clerk, %{"body" => "public"})

      for u <- [ctx.admin, ctx.manager, ctx.clerk2, ctx.auditor] do
        assert Notes.get_note(note.id, ctx.company, u)
      end

      refute Notes.get_note(note.id, ctx.company, ctx.guest)
    end

    test "restricted note: listed role, admin and author read; others do not", ctx do
      note =
        note_fixture(ctx.company, ctx.clerk, %{"body" => "secret", "visibility" => ["manager"]})

      assert Notes.get_note(note.id, ctx.company, ctx.manager)
      assert Notes.get_note(note.id, ctx.company, ctx.admin)
      assert Notes.get_note(note.id, ctx.company, ctx.clerk)
      refute Notes.get_note(note.id, ctx.company, ctx.clerk2)
      refute Notes.get_note(note.id, ctx.company, ctx.auditor)
    end

    test "another company never sees the note", ctx do
      note = note_fixture(ctx.company, ctx.admin)
      other = FullCircle.SysFixtures.company_fixture(ctx.admin, %{})
      refute Notes.get_note(note.id, other, ctx.admin)
    end

    test "a disabled user reads nothing, even their own note", ctx do
      note = note_fixture(ctx.company, ctx.clerk)

      {:ok, _} =
        FullCircle.Sys.change_user_role_in(ctx.company, ctx.clerk.id, "disable", ctx.admin)

      refute Notes.get_note(note.id, ctx.company, ctx.clerk)
    end
  end

  describe "create_note/3" do
    test "stores author, subject and normalizes visibility", %{admin: admin, company: company} do
      c = contact_fixture(company, admin)

      assert {:ok, note} =
               Notes.create_note(
                 %{
                   "body" => "pays late",
                   "subject_type" => "Contact",
                   "subject_id" => c.id,
                   "visibility" => ["", "manager", "manager"]
                 },
                 company,
                 admin
               )

      assert note.author_id == admin.id
      assert note.visibility == ["manager"]

      assert {:ok, public} =
               Notes.create_note(%{"body" => "x", "visibility" => [""]}, company, admin)

      assert public.visibility == nil
    end

    test "a subject from another company or an unknown type is rejected", %{
      admin: admin,
      company: company
    } do
      other = FullCircle.SysFixtures.company_fixture(admin, %{})
      foreign = contact_fixture(other, admin)

      assert {:error, cs} =
               Notes.create_note(
                 %{"body" => "x", "subject_type" => "Contact", "subject_id" => foreign.id},
                 company,
                 admin
               )

      assert %{subject_id: ["not found"]} = errors_on(cs)

      assert {:error, cs} =
               Notes.create_note(
                 %{"body" => "x", "subject_type" => "Nope", "subject_id" => Ecto.UUID.generate()},
                 company,
                 admin
               )

      assert %{subject_type: ["is invalid"]} = errors_on(cs)
    end

    test "creates links in the same transaction; a bad link rolls back", %{
      admin: admin,
      company: company
    } do
      c = contact_fixture(company, admin)

      assert {:ok, note} =
               Notes.create_note(
                 %{"body" => "x", "links" => [%{"type" => "Contact", "id" => c.id}]},
                 company,
                 admin
               )

      assert [%{type: "Contact", id: id}] = Notes.list_links(note, company, admin)
      assert id == c.id

      count = Repo.aggregate(FullCircle.Notes.Note, :count)

      assert {:error, {:link, :not_found}} =
               Notes.create_note(
                 %{
                   "body" => "y",
                   "links" => [%{"type" => "Contact", "id" => Ecto.UUID.generate()}]
                 },
                 company,
                 admin
               )

      assert Repo.aggregate(FullCircle.Notes.Note, :count) == count
    end

    test "auditor and guest cannot create", %{admin: admin, company: company} do
      for role <- ~w(auditor guest) do
        u = user_with_role(company, admin, role)
        assert :not_authorise = Notes.create_note(%{"body" => "x"}, company, u)
      end
    end
  end

  describe "update_note/4" do
    test "an edit writes exactly one version of the old content", %{
      admin: admin,
      company: company
    } do
      note = note_fixture(company, admin, %{"body" => "v1"})
      assert {:ok, note} = Notes.update_note(note, %{"body" => "v2"}, company, admin)
      assert note.body == "v2"

      assert [%{version: 1, body: "v1", edited_by_id: eid}] =
               Notes.list_versions(note, company, admin)

      assert eid == admin.id
    end

    test "a no-op edit writes no version", %{admin: admin, company: company} do
      note = note_fixture(company, admin, %{"body" => "same"})
      assert {:ok, _} = Notes.update_note(note, %{"body" => "same"}, company, admin)
      assert [] = Notes.list_versions(note, company, admin)
    end

    test "a concurrent edit is stale and writes nothing", %{admin: admin, company: company} do
      note = note_fixture(company, admin, %{"body" => "v1"})
      {:ok, _} = Notes.update_note(note, %{"body" => "theirs"}, company, admin)

      assert {:error, :stale} = Notes.update_note(note, %{"body" => "mine"}, company, admin)
      assert Notes.get_note(note.id, company, admin).body == "theirs"
      assert length(Notes.list_versions(note, company, admin)) == 1
    end

    test "author edits own; others need admin/manager AND read access", %{
      admin: admin,
      company: company
    } do
      clerk = user_with_role(company, admin, "clerk")
      clerk2 = user_with_role(company, admin, "clerk")
      manager = user_with_role(company, admin, "manager")

      mine = note_fixture(company, clerk, %{"body" => "a"})
      assert {:ok, mine} = Notes.update_note(mine, %{"body" => "b"}, company, clerk)
      assert :not_authorise = Notes.update_note(mine, %{"body" => "c"}, company, clerk2)
      assert {:ok, _} = Notes.update_note(mine, %{"body" => "d"}, company, manager)

      hidden = note_fixture(company, clerk, %{"body" => "a", "visibility" => ["supervisor"]})
      assert {:error, :not_found} = Notes.update_note(hidden, %{"body" => "z"}, company, manager)
    end
  end

  describe "delete_note/3" do
    test "soft-deletes, snapshots a version, hides everywhere", %{admin: admin, company: company} do
      note = note_fixture(company, admin, %{"body" => "bye"})
      assert {:ok, _} = Notes.delete_note(note, company, admin)
      refute Notes.get_note(note.id, company, admin)
      assert %{deleted_at: %DateTime{}} = Repo.get!(FullCircle.Notes.Note, note.id)
      assert [%{body: "bye"}] = Repo.all(FullCircle.Notes.NoteVersion)
    end

    test "clerk cannot delete another's note", %{admin: admin, company: company} do
      clerk = user_with_role(company, admin, "clerk")
      note = note_fixture(company, admin)
      assert :not_authorise = Notes.delete_note(note, company, clerk)
    end
  end
end
