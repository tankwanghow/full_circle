defmodule FullCircle.NotesTest do
  use FullCircle.DataCase

  import Ecto.Query

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

  describe "links and record queries" do
    setup %{admin: admin, company: company} do
      c = contact_fixture(company, admin)
      clerk = user_with_role(company, admin, "clerk")
      %{contact: c, clerk: clerk}
    end

    test "add/remove link; duplicate and self links rejected", %{
      admin: admin,
      company: company,
      contact: c
    } do
      note = note_fixture(company, admin)
      assert {:ok, link} = Notes.add_link(note, "Contact", c.id, company, admin)
      assert {:error, cs} = Notes.add_link(note, "Contact", c.id, company, admin)
      assert %{to_id: ["already linked"]} = errors_on(cs)
      assert {:error, cs} = Notes.add_link(note, "Note", note.id, company, admin)
      assert %{to_id: ["cannot link to itself"]} = errors_on(cs)

      assert {:error, :not_found} =
               Notes.add_link(note, "Contact", Ecto.UUID.generate(), company, admin)

      assert {:ok, _} = Notes.remove_link(note, link.id, company, admin)
      assert [] = Notes.list_links(note, company, admin)
    end

    test "a linked record deleted later resolves to not_found, not a crash", %{
      admin: admin,
      company: company
    } do
      other = note_fixture(company, admin, %{"body" => "target"})
      note = note_fixture(company, admin)
      {:ok, _} = Notes.add_link(note, "Note", other.id, company, admin)
      {:ok, _} = Notes.delete_note(other, company, admin)
      assert [%{target: {:error, :not_found}}] = Notes.list_links(note, company, admin)
    end

    test "backlinks show only visible notes", %{admin: admin, company: company, clerk: clerk} do
      target = note_fixture(company, admin, %{"body" => "target"})
      open = note_fixture(company, admin, %{"body" => "open"})
      hidden = note_fixture(company, admin, %{"body" => "hidden", "visibility" => ["manager"]})
      {:ok, _} = Notes.add_link(open, "Note", target.id, company, admin)
      {:ok, _} = Notes.add_link(hidden, "Note", target.id, company, admin)

      assert [%{body: "open"}] = Notes.list_backlinks(target, company, clerk)
      assert length(Notes.list_backlinks(target, company, admin)) == 2
    end

    test "notes_for_record: about + linked, no duplicates, visibility applied",
         %{admin: admin, company: company, contact: c, clerk: clerk} do
      about =
        note_fixture(company, admin, %{
          "body" => "about",
          "subject_type" => "Contact",
          "subject_id" => c.id
        })

      {:ok, _} = Notes.add_link(about, "Contact", c.id, company, admin)
      linked = note_fixture(company, admin, %{"body" => "linked"})
      {:ok, _} = Notes.add_link(linked, "Contact", c.id, company, admin)

      _hidden =
        note_fixture(company, admin, %{
          "body" => "hidden",
          "subject_type" => "Contact",
          "subject_id" => c.id,
          "visibility" => ["manager"]
        })

      rows = Notes.notes_for_record("Contact", c.id, company, clerk)

      assert Enum.map(rows, &{&1.note.body, &1.relation}) |> Enum.sort() ==
               [{"about", :about}, {"linked", :linked}]
    end

    test "count_by_records respects visibility and counts each note once",
         %{admin: admin, company: company, contact: c, clerk: clerk} do
      c2 = contact_fixture(company, admin)
      a = note_fixture(company, admin, %{"subject_type" => "Contact", "subject_id" => c.id})
      {:ok, _} = Notes.add_link(a, "Contact", c.id, company, admin)
      b = note_fixture(company, admin)
      {:ok, _} = Notes.add_link(b, "Contact", c.id, company, admin)

      note_fixture(company, admin, %{
        "subject_type" => "Contact",
        "subject_id" => c.id,
        "visibility" => ["manager"]
      })

      assert Notes.count_by_records(company, clerk, "Contact", [c.id, c2.id]) == %{c.id => 2}
      assert Notes.count_by_records(company, admin, "Contact", [c.id, c2.id]) == %{c.id => 3}
    end
  end

  describe "search/5" do
    setup %{admin: admin, company: company} do
      clerk = user_with_role(company, admin, "clerk")
      note_fixture(company, admin, %{"title" => "Welding", "body" => "Ali can weld aluminium"})
      note_fixture(company, admin, %{"body" => "Ah Seng pays 100% late"})
      note_fixture(company, admin, %{"body" => "焊工 很好"})
      note_fixture(company, admin, %{"body" => "secret weld", "visibility" => ["manager"]})
      %{clerk: clerk}
    end

    defp bodies(list), do: list |> Enum.map(& &1.body) |> Enum.sort()

    test "every word must match title or body, visibility applied", %{
      company: company,
      clerk: clerk
    } do
      assert bodies(Notes.search(company, clerk, "weld", %{}, page: 1, per_page: 30)) ==
               ["Ali can weld aluminium"]
    end

    test "admin sees the restricted match too", %{company: company, admin: admin} do
      assert length(Notes.search(company, admin, "weld", %{}, page: 1, per_page: 30)) == 2
    end

    test "LIKE metacharacters are literal", %{company: company, clerk: clerk} do
      assert bodies(Notes.search(company, clerk, "100%", %{}, page: 1, per_page: 30)) ==
               ["Ah Seng pays 100% late"]
    end

    test "Chinese text is found", %{company: company, clerk: clerk} do
      assert bodies(Notes.search(company, clerk, "焊工", %{}, page: 1, per_page: 30)) == ["焊工 很好"]
    end

    test "empty terms list newest first and paginate", %{company: company, admin: admin} do
      assert length(Notes.search(company, admin, "", %{}, page: 1, per_page: 3)) == 3
      assert length(Notes.search(company, admin, "", %{}, page: 2, per_page: 3)) == 1
    end

    test "mine and subject filters", %{company: company, admin: admin, clerk: clerk} do
      c = contact_fixture(company, admin)

      note_fixture(company, clerk, %{
        "body" => "clerk's",
        "subject_type" => "Contact",
        "subject_id" => c.id
      })

      assert bodies(Notes.search(company, clerk, "", %{"mine" => "true"}, page: 1, per_page: 30)) ==
               ["clerk's"]

      assert bodies(
               Notes.search(
                 company,
                 admin,
                 "",
                 %{"subject_type" => "Contact", "subject_id" => c.id},
                 page: 1,
                 per_page: 30
               )
             ) == ["clerk's"]
    end
  end

  describe "version_changes/2" do
    test "lists changed fields per version", %{admin: admin, company: company} do
      note = note_fixture(company, admin, %{"body" => "v1"})
      {:ok, note} = Notes.update_note(note, %{"body" => "v2"}, company, admin)
      {:ok, note} = Notes.update_note(note, %{"title" => "T"}, company, admin)
      versions = Notes.list_versions(note, company, admin)

      assert [
               %{version: %{version: 2}, changes: [{:title, nil, "T"}]},
               %{version: %{version: 1}, changes: [{:body, "v1", "v2"}]}
             ] = Notes.version_changes(versions, note)
    end
  end

  test "search with a malformed subject_id filter matches nothing instead of raising",
       %{admin: admin, company: company} do
    note_fixture(company, admin, %{"body" => "anything"})

    assert Notes.search(company, admin, "", %{"subject_id" => "not-a-uuid"},
             page: 1,
             per_page: 30
           ) ==
             []
  end

  describe "review fixes" do
    setup %{admin: admin, company: company} do
      %{
        clerk: user_with_role(company, admin, "clerk"),
        manager: user_with_role(company, admin, "manager")
      }
    end

    test "history shows each version only to those who could read it then",
         %{admin: admin, company: company, clerk: clerk, manager: manager} do
      note =
        note_fixture(company, manager, %{
          "body" => "salary dispute details",
          "visibility" => ["manager"]
        })

      {:ok, note} =
        Notes.update_note(note, %{"body" => "resolved", "visibility" => []}, company, manager)

      {:ok, note} = Notes.update_note(note, %{"body" => "resolved, closed"}, company, manager)

      clerk_versions = Notes.list_versions(note, company, clerk)
      refute Enum.any?(clerk_versions, &(&1.body =~ "salary"))
      assert [%{body: "resolved"}] = clerk_versions

      # The diff a clerk sees never names the hidden text either.
      for %{changes: changes} <- Notes.version_changes(clerk_versions, note),
          {_f, old, new} <- changes do
        refute to_string(old) =~ "salary"
        refute to_string(new) =~ "salary"
      end

      assert length(Notes.list_versions(note, company, manager)) == 2
      assert length(Notes.list_versions(note, company, admin)) == 2
    end

    test "the author sees every version of their own note",
         %{company: company, clerk: clerk} do
      note = note_fixture(company, clerk, %{"body" => "v1", "visibility" => ["manager"]})
      {:ok, note} = Notes.update_note(note, %{"body" => "v2"}, company, clerk)
      assert [%{body: "v1"}] = Notes.list_versions(note, company, clerk)
    end

    test "a note whose subject disappeared can still be edited", %{admin: admin, company: company} do
      target = note_fixture(company, admin, %{"body" => "target"})

      note =
        note_fixture(company, admin, %{
          "body" => "about target",
          "subject_type" => "Note",
          "subject_id" => target.id
        })

      {:ok, _} = Notes.delete_note(target, company, admin)

      assert {:ok, updated} =
               Notes.update_note(
                 note,
                 %{"body" => "typo fixed", "subject_type" => "Note", "subject_id" => target.id},
                 company,
                 admin
               )

      assert updated.body == "typo fixed"
      assert updated.subject_id == target.id

      # Pointing it at a new missing record is still refused.
      assert {:error, cs} =
               Notes.update_note(updated, %{"subject_id" => Ecto.UUID.generate()}, company, admin)

      assert %{subject_id: ["not found"]} = errors_on(cs)
    end

    test "a cashier can write a note about a credit note they cannot edit",
         %{company: company, admin: admin} do
      cashier = user_with_role(company, admin, "cashier")
      refute FullCircle.Authorization.can?(cashier, :update_credit_note, company)
      cn = FullCircle.DebCreFixtures.credit_note_fixture(company, admin)

      assert {:ok, note} =
               Notes.create_note(
                 %{"body" => "x", "subject_type" => "CreditNote", "subject_id" => cn.id},
                 company,
                 cashier
               )

      assert note.subject_id == cn.id
    end

    test "date filters use the company's day, not UTC's", %{admin: admin, company: company} do
      note = note_fixture(company, admin, %{"body" => "early morning"})

      # 07:30 on 29 Sep in Kuala Lumpur is 23:30 on 28 Sep UTC.
      from(n in FullCircle.Notes.Note, where: n.id == ^note.id)
      |> Repo.update_all(set: [inserted_at: ~U[2026-09-28 23:30:00Z]])

      on_29th = %{"from" => "2026-09-29", "to" => "2026-09-29"}
      on_28th = %{"from" => "2026-09-28", "to" => "2026-09-28"}

      assert [%{body: "early morning"}] =
               Notes.search(company, admin, "", on_29th, page: 1, per_page: 30)

      assert [] = Notes.search(company, admin, "", on_28th, page: 1, per_page: 30)
    end

    test "edit rights for a list match can_edit? note by note",
         %{admin: admin, company: company, clerk: clerk, manager: manager} do
      mine = note_fixture(company, clerk, %{"body" => "mine"})
      theirs = note_fixture(company, admin, %{"body" => "theirs"})
      notes = [mine, theirs]

      for u <- [admin, clerk, manager] do
        rights = Notes.rights(company, u)

        for n <- notes do
          assert Notes.may_edit?(n, u, rights) == Notes.can_edit?(n, company, u)
        end
      end
    end
  end

  describe "feed_details/3" do
    test "subject, links and reply counts for a page of notes, visibility applied",
         %{admin: admin, company: company} do
      clerk = user_with_role(company, admin, "clerk")
      c = contact_fixture(company, admin, %{"name" => "Ah Seng"})
      inv = invoice_fixture(company, admin)

      note =
        note_fixture(company, admin, %{
          "body" => "visit",
          "subject_type" => "Contact",
          "subject_id" => c.id,
          "links" => [%{"type" => "Invoice", "id" => inv.id}]
        })

      plain = note_fixture(company, admin, %{"body" => "plain"})

      note_fixture(company, admin, %{
        "body" => "reply",
        "subject_type" => "Note",
        "subject_id" => note.id
      })

      note_fixture(company, admin, %{
        "body" => "hidden reply",
        "subject_type" => "Note",
        "subject_id" => note.id,
        "visibility" => ["manager"]
      })

      details = Notes.feed_details([note, plain], company, clerk)

      assert %{subject: {:ok, %{title: "Ah Seng"}}, links: [link], replies: 1} = details[note.id]
      assert {link.type, link.id} == {"Invoice", inv.id}
      assert {:ok, _} = link.target
      assert %{subject: nil, links: [], replies: 0} = details[plain.id]
      assert Notes.feed_details([], company, clerk) == %{}
    end
  end
end
