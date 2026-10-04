defmodule FullCircle.NotesTraysTest do
  use FullCircle.DataCase

  import FullCircle.BillingFixtures
  import FullCircle.NotesFixtures

  alias FullCircle.Notes
  alias FullCircle.Notes.{Attachments, NoteAttachment, NoteTray, Trays}

  setup do
    %{admin: admin, company: company} = billing_setup()
    %{admin: admin, company: company, note: note_fixture(company, admin)}
  end

  describe "note_xor_tray" do
    setup ctx do
      tray = Repo.insert!(%NoteTray{company_id: ctx.company.id, user_id: ctx.admin.id})

      base = %{
        file_name: "a.jpg",
        content_type: "image/jpeg",
        byte_size: 1,
        path: "x",
        company_id: ctx.company.id,
        uploaded_by_id: ctx.admin.id
      }

      %{tray: tray, base: base}
    end

    defp insert(attrs), do: %NoteAttachment{} |> NoteAttachment.changeset(attrs) |> Repo.insert()

    test "neither note nor tray is refused", ctx do
      assert {:error, cs} = insert(ctx.base)
      assert {"must belong to a note or a tray", _} = cs.errors[:note_id]
    end

    test "both note and tray is refused", ctx do
      assert {:error, _} =
               insert(Map.merge(ctx.base, %{note_id: ctx.note.id, tray_id: ctx.tray.id}))
    end

    test "a tray alone or a note alone is fine", ctx do
      assert {:ok, _} = insert(Map.put(ctx.base, :tray_id, ctx.tray.id))
      assert {:ok, _} = insert(Map.put(ctx.base, :note_id, ctx.note.id))
    end
  end

  describe "trays" do
    test "open creates once and is idempotent for its owner", ctx do
      id = Ecto.UUID.generate()
      assert {:ok, %NoteTray{id: ^id}} = Trays.open(id, ctx.company, ctx.admin)
      assert {:ok, %NoteTray{id: ^id}} = Trays.open(id, ctx.company, ctx.admin)
      assert Repo.aggregate(NoteTray, :count) == 1
    end

    test "another user cannot open, read or fill someone's tray", ctx do
      tray = tray_fixture(ctx.company, ctx.admin)
      clerk = user_with_role(ctx.company, ctx.admin, "clerk")

      assert {:error, :not_found} = Trays.open(tray.id, ctx.company, clerk)

      assert {:error, :not_found} =
               Attachments.attach_to_tray(
                 tray.id,
                 %{path: jpeg_file(), file_name: "a.jpg"},
                 ctx.company,
                 clerk
               )

      assert Trays.list(tray.id, ctx.company, clerk) == []
    end

    test "a tray upload is stored under notes/tray/<id>, listed, and broadcast", ctx do
      tray = tray_fixture(ctx.company, ctx.admin)
      Phoenix.PubSub.subscribe(FullCircle.PubSub, Attachments.topic(ctx.company.id))

      assert {:ok, att} =
               Attachments.attach_to_tray(
                 tray.id,
                 %{path: jpeg_file(), file_name: "a.jpg"},
                 ctx.company,
                 ctx.admin
               )

      assert att.tray_id == tray.id and is_nil(att.note_id)
      assert String.starts_with?(att.path, "#{ctx.company.id}/notes/tray/#{tray.id}/")
      assert [%{id: id}] = Trays.list(tray.id, ctx.company, ctx.admin)
      assert id == att.id
      tray_id = tray.id
      assert_receive {:note_files_changed, {:tray, ^tray_id}}
    end

    test "a note upload broadcasts its note", ctx do
      Phoenix.PubSub.subscribe(FullCircle.PubSub, Attachments.topic(ctx.company.id))

      {:ok, _} =
        Attachments.attach(
          ctx.note,
          %{path: jpeg_file(), file_name: "a.jpg"},
          ctx.company,
          ctx.admin
        )

      note_id = ctx.note.id
      assert_receive {:note_files_changed, {:note, ^note_id}}
    end

    test "discard_file hard-deletes the row and the file", ctx do
      tray = tray_fixture(ctx.company, ctx.admin)

      {:ok, att} =
        Attachments.attach_to_tray(
          tray.id,
          %{path: jpeg_file(), file_name: "a.jpg"},
          ctx.company,
          ctx.admin
        )

      path = Attachments.abs_path(att)
      assert :ok = Trays.discard_file(att.id, tray.id, ctx.company, ctx.admin)
      refute File.exists?(path)
      assert Repo.get(NoteAttachment, att.id) == nil
    end

    test "cancel deletes every file and closes the tray; later uploads are refused", ctx do
      tray = tray_fixture(ctx.company, ctx.admin)
      up = %{path: jpeg_file(), file_name: "a.jpg"}
      {:ok, a1} = Attachments.attach_to_tray(tray.id, up, ctx.company, ctx.admin)

      {:ok, a2} =
        Attachments.attach_to_tray(tray.id, %{up | path: jpeg_file()}, ctx.company, ctx.admin)

      assert :ok = Trays.cancel(tray.id, ctx.company, ctx.admin)
      refute File.exists?(Attachments.abs_path(a1))
      refute File.exists?(Attachments.abs_path(a2))
      assert Trays.list(tray.id, ctx.company, ctx.admin) == []
      assert %NoteTray{closed_at: %DateTime{}} = Repo.get(NoteTray, tray.id)

      assert {:error, :tray_closed} =
               Attachments.attach_to_tray(
                 tray.id,
                 %{path: jpeg_file(), file_name: "late.jpg"},
                 ctx.company,
                 ctx.admin
               )
    end

    test "an upload into a saved tray follows it to the note", ctx do
      tray = tray_fixture(ctx.company, ctx.admin)

      tray
      |> Ecto.Changeset.change(note_id: ctx.note.id, closed_at: DateTime.utc_now(:second))
      |> Repo.update!()

      assert {:ok, att} =
               Attachments.attach_to_tray(
                 tray.id,
                 %{path: jpeg_file(), file_name: "late.jpg"},
                 ctx.company,
                 ctx.admin
               )

      assert att.note_id == ctx.note.id and is_nil(att.tray_id)

      assert [%{file_name: "late.jpg"}] =
               Notes.get_note(ctx.note.id, ctx.company, ctx.admin).attachments
    end
  end

  describe "save claims the tray" do
    defp tray_with_file(ctx) do
      tray = tray_fixture(ctx.company, ctx.admin)

      {:ok, att} =
        Attachments.attach_to_tray(
          tray.id,
          %{path: jpeg_file(), file_name: "scan.jpg"},
          ctx.company,
          ctx.admin
        )

      {tray, att}
    end

    test "create_note attaches the tray's files and closes it as saved", ctx do
      {tray, att} = tray_with_file(ctx)

      assert {:ok, note} =
               Notes.create_note(
                 %{"body" => "with file", "tray_id" => tray.id},
                 ctx.company,
                 ctx.admin
               )

      assert [%{id: id}] = note.attachments
      assert id == att.id
      assert %{note_id: note_id, closed_at: %DateTime{}} = Repo.get(NoteTray, tray.id)
      assert note_id == note.id
    end

    test "a failed create (invalid) leaves the tray as it was", ctx do
      {tray, _att} = tray_with_file(ctx)

      assert {:error, %Ecto.Changeset{}} =
               Notes.create_note(
                 %{"body" => "x", "visibility" => ["nonsense"], "tray_id" => tray.id},
                 ctx.company,
                 ctx.admin
               )

      assert [_] = Trays.list(tray.id, ctx.company, ctx.admin)
      assert %{closed_at: nil} = Repo.get(NoteTray, tray.id)
    end

    test "update_note with only new files (no field change) still claims", ctx do
      {tray, _att} = tray_with_file(ctx)

      assert {:ok, note} =
               Notes.update_note(ctx.note, %{"tray_id" => tray.id}, ctx.company, ctx.admin)

      assert [%{file_name: "scan.jpg"}] = note.attachments
    end

    test "a stale update leaves the tray as it was", ctx do
      {tray, _att} = tray_with_file(ctx)
      {:ok, _} = Notes.update_note(ctx.note, %{"body" => "someone else"}, ctx.company, ctx.admin)

      assert {:error, :stale} =
               Notes.update_note(
                 ctx.note,
                 %{"body" => "mine", "tray_id" => tray.id},
                 ctx.company,
                 ctx.admin
               )

      assert [_] = Trays.list(tray.id, ctx.company, ctx.admin)
    end

    test "a tray id from another user is ignored, not claimed", ctx do
      {tray, _att} = tray_with_file(ctx)
      manager = user_with_role(ctx.company, ctx.admin, "manager")

      assert {:ok, note} =
               Notes.create_note(%{"body" => "x", "tray_id" => tray.id}, ctx.company, manager)

      assert note.attachments == []
      assert [_] = Trays.list(tray.id, ctx.company, ctx.admin)
    end
  end

  describe "prune_before" do
    test "removes old trays and their unsaved files, never a note's files", ctx do
      old = tray_fixture(ctx.company, ctx.admin)
      fresh = tray_fixture(ctx.company, ctx.admin)
      up = fn -> %{path: jpeg_file(), file_name: "a.jpg"} end
      {:ok, old_att} = Attachments.attach_to_tray(old.id, up.(), ctx.company, ctx.admin)
      {:ok, _} = Attachments.attach_to_tray(fresh.id, up.(), ctx.company, ctx.admin)
      {:ok, note_att} = Attachments.attach(ctx.note, up.(), ctx.company, ctx.admin)

      two_days_ago = DateTime.add(DateTime.utc_now(:second), -2, :day)

      Repo.update_all(from(t in NoteTray, where: t.id == ^old.id),
        set: [inserted_at: two_days_ago]
      )

      assert {:ok, %{trays: 1, files: 1}} =
               Trays.prune_before(DateTime.add(DateTime.utc_now(), -1, :day))

      refute File.exists?(Attachments.abs_path(old_att))
      assert Repo.get(NoteTray, old.id) == nil
      assert Repo.get(NoteTray, fresh.id)
      assert File.exists?(Attachments.abs_path(note_att))
    end
  end

  describe "an upload racing Save or Cancel" do
    # The phone saw the tray open (Trays.get), then Save/Cancel committed
    # before its insert. store_in_tray/4 takes the tray as last seen; the
    # state that counts is re-read under lock at insert time.
    test "landing after Save goes onto the saved note", ctx do
      seen_open = tray_fixture(ctx.company, ctx.admin)

      {:ok, note} =
        Notes.create_note(%{"body" => "x", "tray_id" => seen_open.id}, ctx.company, ctx.admin)

      assert {:ok, att} =
               Attachments.store_in_tray(
                 seen_open,
                 %{path: jpeg_file(), file_name: "late.jpg"},
                 ctx.company,
                 ctx.admin
               )

      assert att.note_id == note.id and is_nil(att.tray_id)
    end

    test "landing after Cancel is refused and leaves nothing behind", ctx do
      seen_open = tray_fixture(ctx.company, ctx.admin)
      :ok = Trays.cancel(seen_open.id, ctx.company, ctx.admin)

      assert {:error, :tray_closed} =
               Attachments.store_in_tray(
                 seen_open,
                 %{path: jpeg_file(), file_name: "late.jpg"},
                 ctx.company,
                 ctx.admin
               )

      assert Repo.aggregate(from(a in NoteAttachment, where: a.tray_id == ^seen_open.id), :count) ==
               0

      assert File.ls(
               Path.join([
                 Attachments.uploads_dir(),
                 ctx.company.id,
                 "notes",
                 "tray",
                 seen_open.id
               ])
             ) in [{:ok, []}, {:error, :enoent}]
    end
  end

  describe "a note may be files only" do
    defp tray_with_photo(ctx) do
      tray = tray_fixture(ctx.company, ctx.admin)

      {:ok, _} =
        Attachments.attach_to_tray(
          tray.id,
          %{path: jpeg_file(), file_name: "photo.jpg"},
          ctx.company,
          ctx.admin
        )

      tray
    end

    test "no text but files in the tray saves", ctx do
      tray = tray_with_photo(ctx)

      assert {:ok, note} =
               Notes.create_note(%{"body" => "", "tray_id" => tray.id}, ctx.company, ctx.admin)

      assert note.body == ""
      assert [%{file_name: "photo.jpg"}] = note.attachments
    end

    test "a reply of files only saves", ctx do
      tray = tray_with_photo(ctx)

      assert {:ok, reply} =
               Notes.create_note(
                 %{"body" => "", "tray_id" => tray.id, "reply_to_id" => ctx.note.id},
                 ctx.company,
                 ctx.admin
               )

      assert reply.reply_to_id == ctx.note.id
    end

    test "no text and no files is still refused", ctx do
      assert {:error, cs} = Notes.create_note(%{"body" => ""}, ctx.company, ctx.admin)
      assert {"can't be blank", _} = cs.errors[:body]

      empty_tray = tray_fixture(ctx.company, ctx.admin)

      assert {:error, _} =
               Notes.create_note(
                 %{"body" => "", "tray_id" => empty_tray.id},
                 ctx.company,
                 ctx.admin
               )
    end

    test "editing away the text keeps the note when it already has files", ctx do
      {:ok, _} =
        Attachments.attach(
          ctx.note,
          %{path: jpeg_file(), file_name: "a.jpg"},
          ctx.company,
          ctx.admin
        )

      assert {:ok, note} = Notes.update_note(ctx.note, %{"body" => ""}, ctx.company, ctx.admin)
      assert note.body == ""
    end

    test "editing away the text of a note without files is refused", ctx do
      assert {:error, %Ecto.Changeset{}} =
               Notes.update_note(ctx.note, %{"body" => ""}, ctx.company, ctx.admin)
    end
  end

  test "a files-only note still has a name in links, chips and search" do
    alias FullCircle.Notes.Note
    assert Note.display_title(%Note{title: nil, body: ""}) == "📎 Files"
    assert Note.display_title(%Note{title: nil, body: "  \n"}) == "📎 Files"
    assert Note.display_title(%Note{title: nil, body: "Bank letter\nmore"}) == "Bank letter"

    assert FullCircleWeb.PhoneUpload.note_label(%Note{title: nil, body: ""}) == "📎 Files"
  end
end
