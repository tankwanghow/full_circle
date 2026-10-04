defmodule FullCircle.NotesTraysTest do
  use FullCircle.DataCase

  import FullCircle.BillingFixtures
  import FullCircle.NotesFixtures

  alias FullCircle.Notes.{NoteAttachment, NoteTray}

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
end
