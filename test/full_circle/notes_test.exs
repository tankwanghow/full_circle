defmodule FullCircle.NotesTest do
  use FullCircle.DataCase

  import Ecto.Query

  import FullCircle.BillingFixtures
  import FullCircle.NotesFixtures
  import FullCircle.TasksFixtures

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

    test "guest is not a visibility choice (guests cannot open notes); admin alone means private" do
      cs = Note.changeset(%Note{}, %{"body" => "b", "visibility" => ["guest"]})
      assert %{visibility: ["has an invalid entry"]} = errors_on(cs)

      assert Note.changeset(%Note{}, %{"body" => "b", "visibility" => ["admin"]}).valid?
      assert Note.private?(%Note{visibility: ["admin"]})
      refute Note.private?(%Note{visibility: ["admin", "clerk"]})
      refute Note.private?(%Note{visibility: nil})
      refute "admin" in Note.choosable_roles()
      refute "guest" in Note.choosable_roles()
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

  describe "private notes" do
    test "admin alone is private; admin next to roles is dropped (admins always read)",
         %{admin: admin, company: company} do
      {:ok, private} =
        Notes.create_note(%{"body" => "p", "visibility" => ["", "admin"]}, company, admin)

      assert private.visibility == ["admin"]

      {:ok, shared} =
        Notes.create_note(
          %{"body" => "s", "visibility" => ["", "admin", "clerk"]},
          company,
          admin
        )

      assert shared.visibility == ["clerk"]
    end

    test "a private note is read by admins and the writer only", %{admin: admin, company: company} do
      clerk = user_with_role(company, admin, "clerk")
      manager = user_with_role(company, admin, "manager")
      note = note_fixture(company, clerk, %{"body" => "private", "visibility" => ["admin"]})

      assert Notes.get_note(note.id, company, admin)
      assert Notes.get_note(note.id, company, clerk)
      refute Notes.get_note(note.id, company, manager)
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

    test "notes_for_record limit: newest n across about and linked notes",
         %{admin: admin, company: company, contact: c} do
      at = fn note, min ->
        from(n in FullCircle.Notes.Note, where: n.id == ^note.id)
        |> Repo.update_all(
          set: [inserted_at: DateTime.add(~U[2026-10-01 00:00:00Z], min, :minute)]
        )
      end

      about = fn body ->
        note_fixture(company, admin, %{
          "body" => body,
          "subject_type" => "Contact",
          "subject_id" => c.id
        })
      end

      linked = fn body ->
        n = note_fixture(company, admin, %{"body" => body})
        {:ok, _} = Notes.add_link(n, "Contact", c.id, company, admin)
        n
      end

      at.(about.("a1"), 1)
      at.(linked.("l2"), 2)
      at.(about.("a3"), 3)
      at.(linked.("l4"), 4)

      both = about.("both5")
      {:ok, _} = Notes.add_link(both, "Contact", c.id, company, admin)
      at.(both, 5)

      rows = Notes.notes_for_record("Contact", c.id, company, admin, limit: 3)

      assert Enum.map(rows, &{&1.note.body, &1.relation}) ==
               [{"both5", :about}, {"l4", :linked}, {"a3", :about}]

      assert length(Notes.notes_for_record("Contact", c.id, company, admin)) == 5
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

    test "a reply shows where its root links, as a reply shows where its root is about",
         %{admin: admin, company: company, contact: c} do
      root = note_fixture(company, admin, %{"body" => "root"})
      {:ok, link} = Notes.add_link(root, "Contact", c.id, company, admin)
      note_fixture(company, admin, %{"body" => "reply", "reply_to_id" => root.id})

      # Linking the record itself as well must not show the reply twice.
      also = note_fixture(company, admin, %{"body" => "also links", "reply_to_id" => root.id})
      {:ok, _} = Notes.add_link(also, "Contact", c.id, company, admin)

      rows = Notes.notes_for_record("Contact", c.id, company, admin)

      assert Enum.map(rows, &{&1.note.body, &1.relation}) |> Enum.sort() ==
               [{"also links", :linked}, {"reply", :linked}, {"root", :linked}]

      assert Notes.count_by_records(company, admin, "Contact", [c.id]) == %{c.id => 3}

      # Nothing is copied: unlinking the root takes its plain reply with it.
      {:ok, _} = Notes.remove_link(root, link.id, company, admin)

      assert [%{note: %{body: "also links"}}] =
               Notes.notes_for_record("Contact", c.id, company, admin)

      assert Notes.count_by_records(company, admin, "Contact", [c.id]) == %{c.id => 1}
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

    test "a word may match the name of a record the note is about or links to", %{
      company: company,
      admin: admin
    } do
      mei = contact_fixture(company, admin, %{"name" => "Kedai Mei Hua"})
      bolt = good_fixture(company, admin, %{"name" => "Hex Bolt M12"})

      note_fixture(company, admin, %{
        "body" => "about her",
        "subject_type" => "Contact",
        "subject_id" => mei.id
      })

      linked = note_fixture(company, admin, %{"body" => "pump needs a part"})
      {:ok, _} = Notes.add_link(linked, "Good", bolt.id, company, admin)

      search = &bodies(Notes.search(company, admin, &1, %{}, page: 1, per_page: 30))

      assert search.("mei hua") == ["about her"]
      assert search.("bolt") == ["pump needs a part"]
      # Each word may match a different place: the text, or a record's name.
      assert search.("pump M12") == ["pump needs a part"]
      assert search.("pump hua") == []
    end

    test "a linked document matches by its number and its contact's name", %{
      company: company,
      admin: admin
    } do
      inv = invoice_fixture(company, admin)
      contact = FullCircle.Repo.get!(FullCircle.Accounting.Contact, inv.contact_id)
      note = note_fixture(company, admin, %{"body" => "short-shipped"})
      {:ok, _} = Notes.add_link(note, "Invoice", inv.id, company, admin)

      search = &bodies(Notes.search(company, admin, &1, %{}, page: 1, per_page: 30))

      assert search.(inv.invoice_no) == ["short-shipped"]
      assert search.(contact.name) == ["short-shipped"]
    end

    test "a progress note is found by its task's title, open or done", %{
      company: company,
      admin: admin
    } do
      task = task_fixture(company, admin, %{"title" => "JPV Ayam Lesen"})

      note_fixture(company, admin, %{
        "body" => "Renewed",
        "subject_type" => "Task",
        "subject_id" => task.id
      })

      {:ok, _} = FullCircle.Tasks.close_task(task, :done, nil, company, admin)

      assert "Renewed" in bodies(Notes.search(company, admin, "ayam", %{}, page: 1, per_page: 30))
    end

    test "a linked note is found by the title of the note it links to", %{
      company: company,
      admin: admin
    } do
      target = note_fixture(company, admin, %{"title" => "Gate zebra policy", "body" => "x"})
      note = note_fixture(company, admin, %{"body" => "see policy"})
      {:ok, _} = Notes.add_link(note, "Note", target.id, company, admin)

      assert bodies(Notes.search(company, admin, "zebra", %{}, page: 1, per_page: 30)) ==
               ["see policy", "x"]
    end

    # A linked task or note may be one the searcher cannot see; its title
    # must not be searchable through the note that links it.
    test "a linked task's title counts only for those who may see the task", %{
      company: company,
      admin: admin,
      clerk: clerk
    } do
      private =
        task_fixture(company, admin, %{"title" => "Renew zebra permit", "visibility" => ["admin"]})

      note = note_fixture(company, admin, %{"body" => "see task"})
      {:ok, _} = Notes.add_link(note, "Task", private.id, company, admin)

      assert bodies(Notes.search(company, admin, "zebra", %{}, page: 1, per_page: 30)) ==
               ["see task"]

      assert Notes.search(company, clerk, "zebra", %{}, page: 1, per_page: 30) == []
      # The clerk does see the note itself.
      assert "see task" in bodies(Notes.search(company, clerk, "see", %{}, page: 1, per_page: 30))
    end

    test "a linked note's title counts only for those who may read that note", %{
      company: company,
      admin: admin,
      clerk: clerk
    } do
      hidden =
        note_fixture(company, admin, %{
          "title" => "Zebra pay review",
          "body" => "x",
          "visibility" => ["manager"]
        })

      note = note_fixture(company, admin, %{"body" => "see hidden"})
      {:ok, _} = Notes.add_link(note, "Note", hidden.id, company, admin)

      assert "see hidden" in bodies(
               Notes.search(company, admin, "zebra", %{}, page: 1, per_page: 30)
             )

      assert Notes.search(company, clerk, "zebra", %{}, page: 1, per_page: 30) == []
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

      # A reply follows its root's visibility, so it can never be narrower; a
      # note that only links here does not count as a reply.
      note_fixture(company, admin, %{"body" => "reply", "reply_to_id" => note.id})

      note_fixture(company, admin, %{
        "body" => "quote",
        "links" => [%{"type" => "Note", "id" => note.id}]
      })

      details = Notes.feed_details([note, plain], company, clerk)

      assert %{subject: {:ok, %{title: "Ah Seng"}}, links: [link], replies: 1} = details[note.id]
      assert {link.type, link.id} == {"Invoice", inv.id}
      assert {:ok, _} = link.target
      assert %{subject: nil, links: [], replies: 0} = details[plain.id]
      assert Notes.feed_details([], company, clerk) == %{}
    end
  end

  describe "notes about a task" do
    setup %{company: company, admin: admin} do
      manager = user_with_role(company, admin, "manager")
      cashier = user_with_role(company, admin, "cashier")
      clerk = user_with_role(company, admin, "clerk")

      task =
        task_fixture(company, manager, %{
          "title" => "Permit renewal",
          "visibility" => ["admin"],
          "assignee_id" => cashier.id
        })

      note =
        note_fixture(company, manager, %{
          "body" => "submitted to JTK",
          "visibility" => ["admin"],
          "subject_type" => "Task",
          "subject_id" => task.id
        })

      %{manager: manager, cashier: cashier, clerk: clerk, task: task, note: note}
    end

    test "a Private note on a task is readable by whoever sees the task", ctx do
      %{company: company, cashier: cashier, clerk: clerk, note: note} = ctx
      assert Notes.can_read?(note, company, cashier)
      refute Notes.can_read?(note, company, clerk)
    end

    test "absent from a non-viewer's feed, search and counts", ctx do
      %{company: company, clerk: clerk, task: task, note: note} = ctx

      refute note.id in Enum.map(
               Notes.search(company, clerk, "", %{}, page: 1, per_page: 50),
               & &1.id
             )

      refute note.id in Enum.map(
               Notes.search(company, clerk, "JTK", %{}, page: 1, per_page: 50),
               & &1.id
             )

      assert Notes.count_by_records(company, clerk, "Task", [task.id]) == %{}
      assert Notes.count_by_records(company, ctx.cashier, "Task", [task.id]) == %{task.id => 1}
    end

    test "versions follow the task rule", ctx do
      %{company: company, manager: manager, cashier: cashier, note: note} = ctx

      {:ok, edited} =
        Notes.update_note(note, %{"body" => "submitted to JTK on 3/10"}, company, manager)

      assert [%{body: "submitted to JTK"}] = Notes.list_versions(edited, company, cashier)
    end

    test "a version's task rule uses the version's own subject", ctx do
      %{company: company, admin: admin, manager: manager, cashier: cashier, task: task} = ctx
      contact = contact_fixture(company, admin, %{"name" => "Old Subject"})

      note =
        note_fixture(company, manager, %{
          "body" => "managers only secret",
          "visibility" => ["manager"],
          "subject_type" => "Contact",
          "subject_id" => contact.id
        })

      {:ok, edited} = Notes.update_note(note, %{"body" => "second"}, company, manager)

      {:ok, moved} =
        Notes.update_note(
          edited,
          %{
            "body" => "second",
            "visibility" => ["admin"],
            "subject_type" => "Task",
            "subject_id" => task.id
          },
          company,
          manager
        )

      assert Notes.can_read?(moved, company, cashier)
      bodies = Notes.list_versions(moved, company, cashier) |> Enum.map(& &1.body)
      refute "managers only secret" in bodies
    end

    test "attachments on it download for the assignee only", ctx do
      %{company: company, manager: manager, cashier: cashier, clerk: clerk, note: note} = ctx

      {:ok, att} =
        FullCircle.Notes.Attachments.attach(
          note,
          %{path: jpeg_file(), file_name: "p.jpg"},
          company,
          manager
        )

      assert FullCircle.Notes.Attachments.get_readable(att.id, company, cashier)
      refute FullCircle.Notes.Attachments.get_readable(att.id, company, clerk)
    end
  end
end
