defmodule FullCircle.NotesRepliesTest do
  use FullCircle.DataCase, async: false

  import FullCircle.BillingFixtures
  import FullCircle.NotesFixtures
  import FullCircle.TasksFixtures

  alias FullCircle.{Notes, Repo}
  alias FullCircle.Notes.{Note, NoteVersion, ReplyBackfill}

  setup do
    billing_setup()
  end

  defp reply(company, user, root, attrs \\ %{}) do
    Notes.create_note(
      Map.merge(%{"body" => "a reply", "reply_to_id" => root.id}, attrs),
      company,
      user
    )
  end

  describe "creating a reply" do
    test "copies the root's subject and visibility, ignoring the client's", %{
      company: company,
      admin: admin
    } do
      c = contact_fixture(company, admin)

      root =
        note_fixture(company, admin, %{
          "body" => "root",
          "subject_type" => "Contact",
          "subject_id" => c.id,
          "visibility" => ["manager"]
        })

      other = contact_fixture(company, admin)

      {:ok, r} =
        reply(company, admin, root, %{
          "subject_type" => "Contact",
          "subject_id" => other.id,
          "visibility" => [""]
        })

      assert r.reply_to_id == root.id
      assert {r.subject_type, r.subject_id} == {"Contact", c.id}
      assert r.visibility == ["manager"]
    end

    test "a reply to a reply joins the root's thread", %{company: company, admin: admin} do
      root = note_fixture(company, admin, %{"body" => "root"})
      {:ok, r1} = reply(company, admin, root)
      {:ok, r2} = reply(company, admin, r1)
      assert r2.reply_to_id == root.id
    end

    test "a reply to a task note follows the task", %{company: company, admin: admin} do
      task = task_fixture(company, admin, %{"visibility" => ["manager"]})

      root =
        note_fixture(company, admin, %{
          "body" => "progress",
          "subject_type" => "Task",
          "subject_id" => task.id
        })

      {:ok, r} = reply(company, admin, root)
      assert {r.subject_type, r.subject_id, r.visibility} == {"Task", task.id, ["manager"]}
    end

    test "refuses unknown, unreadable, deleted, other-company and malformed targets", %{
      company: company,
      admin: admin
    } do
      clerk = user_with_role(company, admin, "clerk")
      hidden = note_fixture(company, admin, %{"body" => "m", "visibility" => ["manager"]})
      gone = note_fixture(company, admin, %{"body" => "gone"})
      {:ok, _} = Notes.delete_note(gone, company, admin)
      other_company = FullCircle.SysFixtures.company_fixture(admin, %{})
      foreign = note_fixture(other_company, admin, %{"body" => "foreign"})

      for {user, id} <- [
            {clerk, hidden.id},
            {admin, gone.id},
            {admin, foreign.id},
            {admin, Ecto.UUID.generate()},
            {admin, "x"}
          ] do
        assert {:error, cs} =
                 Notes.create_note(%{"body" => "r", "reply_to_id" => id}, company, user)

        assert %{reply_to_id: ["can't be replied to"]} = errors_on(cs)
      end
    end
  end

  describe "editing" do
    test "a reply's subject, visibility and reply_to cannot be changed", %{
      company: company,
      admin: admin
    } do
      root = note_fixture(company, admin, %{"body" => "root", "visibility" => ["manager"]})
      other = note_fixture(company, admin, %{"body" => "other"})
      {:ok, r} = reply(company, admin, root)

      {:ok, r2} =
        Notes.update_note(
          r,
          %{
            "body" => "edited",
            "visibility" => [""],
            "reply_to_id" => other.id,
            "subject_type" => "Note",
            "subject_id" => other.id
          },
          company,
          admin
        )

      assert r2.body == "edited"
      assert r2.visibility == ["manager"]
      assert r2.reply_to_id == root.id
      assert r2.subject_id == nil
    end

    test "a root's subject/visibility change updates its live replies only", %{
      company: company,
      admin: admin
    } do
      c = contact_fixture(company, admin)
      root = note_fixture(company, admin, %{"body" => "root"})
      {:ok, r1} = reply(company, admin, root)
      {:ok, r2} = reply(company, admin, root)
      {:ok, _} = Notes.delete_note(r2, company, admin)
      unrelated = note_fixture(company, admin, %{"body" => "unrelated"})

      {:ok, _} =
        Notes.update_note(
          root,
          %{"visibility" => ["manager"], "subject_type" => "Contact", "subject_id" => c.id},
          company,
          admin
        )

      r1 = Repo.get!(Note, r1.id)
      assert {r1.subject_type, r1.subject_id, r1.visibility} == {"Contact", c.id, ["manager"]}
      assert Repo.get!(Note, r2.id).visibility == nil
      assert Repo.get!(Note, unrelated.id).visibility == nil
    end

    test "narrowing a root hides its replies from those who lost the root", %{
      company: company,
      admin: admin
    } do
      clerk = user_with_role(company, admin, "clerk")
      root = note_fixture(company, admin, %{"body" => "root"})
      {:ok, r} = reply(company, admin, root)
      assert Notes.can_read?(r, company, clerk)
      {:ok, _} = Notes.update_note(root, %{"visibility" => ["manager"]}, company, admin)
      refute Notes.can_read?(Repo.get!(Note, r.id), company, clerk)
    end
  end

  describe "ReplyBackfill" do
    test "turns old note-on-note rows into replies of the true root with a version first", %{
      company: company,
      admin: admin
    } do
      c = contact_fixture(company, admin)

      root =
        note_fixture(company, admin, %{
          "body" => "root",
          "subject_type" => "Contact",
          "subject_id" => c.id,
          "visibility" => ["manager"]
        })

      # Old-style rows: subject is the parent note, no reply_to_id.
      old1 =
        Repo.insert!(%Note{
          company_id: company.id,
          author_id: admin.id,
          updated_by_id: admin.id,
          body: "old1",
          subject_type: "Note",
          subject_id: root.id
        })

      old2 =
        Repo.insert!(%Note{
          company_id: company.id,
          author_id: admin.id,
          updated_by_id: admin.id,
          body: "old2",
          subject_type: "Note",
          subject_id: old1.id
        })

      assert {:ok, 2} = ReplyBackfill.run(Repo)

      for old <- [old1, old2] do
        n = Repo.get!(Note, old.id)
        assert n.reply_to_id == root.id
        assert {n.subject_type, n.subject_id, n.visibility} == {"Contact", c.id, ["manager"]}

        assert [%NoteVersion{subject_type: "Note"}] =
                 Repo.all(from v in NoteVersion, where: v.note_id == ^old.id)
      end

      assert {:ok, 0} = ReplyBackfill.run(Repo)
    end

    test "a cycle does not loop forever", %{company: company, admin: admin} do
      a =
        Repo.insert!(%Note{
          company_id: company.id,
          author_id: admin.id,
          updated_by_id: admin.id,
          body: "a"
        })

      b =
        Repo.insert!(%Note{
          company_id: company.id,
          author_id: admin.id,
          updated_by_id: admin.id,
          body: "b",
          subject_type: "Note",
          subject_id: a.id
        })

      Repo.update!(Ecto.Changeset.change(a, subject_type: "Note", subject_id: b.id))
      assert {:ok, _} = ReplyBackfill.run(Repo)
    end
  end

  describe "reading threads" do
    test "thread lists visible live replies oldest first", %{company: company, admin: admin} do
      root = note_fixture(company, admin, %{"body" => "root"})
      {:ok, a} = reply(company, admin, root, %{"body" => "first"})

      Repo.update_all(from(n in Note, where: n.id == ^a.id),
        set: [inserted_at: ~U[2020-01-01 00:00:00Z]]
      )

      {:ok, b} = reply(company, admin, root, %{"body" => "second"})
      {:ok, c} = reply(company, admin, root, %{"body" => "gone"})
      {:ok, _} = Notes.delete_note(c, company, admin)

      assert Enum.map(Notes.thread(root, company, admin), & &1.id) == [a.id, b.id]
    end

    test "💬 counts replies, not notes that only link", %{company: company, admin: admin} do
      root = note_fixture(company, admin, %{"body" => "root"})
      {:ok, _} = reply(company, admin, root)
      # Two notes only link here; under a "about or linking" count they would make 2.
      for body <- ["quote 1", "quote 2"],
          do:
            note_fixture(company, admin, %{
              "body" => body,
              "links" => [%{"type" => "Note", "id" => root.id}]
            })

      assert %{replies: 1} = Notes.feed_details([root], company, admin)[root.id]
    end

    test "reply_to tag data: ok, deleted, hidden", %{company: company, admin: admin} do
      clerk = user_with_role(company, admin, "clerk")
      root = note_fixture(company, admin, %{"title" => "Genset", "body" => "root"})
      {:ok, r} = reply(company, clerk, root)

      assert %{reply_to: %{id: id, title: "Genset", state: :ok}} =
               Notes.feed_details([r], company, admin)[r.id]

      assert id == root.id

      {:ok, _} = Notes.update_note(root, %{"visibility" => ["manager"]}, company, admin)
      r = Repo.get!(Note, r.id)
      # The clerk wrote the reply, so still reads it (author rule) but not the root.
      assert %{reply_to: %{state: :hidden, title: nil}} =
               Notes.feed_details([r], company, clerk)[r.id]

      assert {:hidden, nil} = Notes.root_of(r, company, clerk)

      {:ok, _} = Notes.delete_note(Repo.get!(Note, root.id), company, admin)
      assert {:deleted, nil} = Notes.root_of(r, company, admin)
      assert %{reply_to: %{state: :deleted}} = Notes.feed_details([r], company, admin)[r.id]
    end
  end
end
