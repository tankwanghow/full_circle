defmodule FullCircle.NotesAttachmentsTest do
  use FullCircle.DataCase

  import FullCircle.BillingFixtures
  import FullCircle.NotesFixtures

  alias FullCircle.Notes
  alias FullCircle.Notes.{Attachments, NoteAttachment}

  setup do
    %{admin: admin, company: company} = billing_setup()
    %{admin: admin, company: company, note: note_fixture(company, admin)}
  end

  test "stores a JPEG under the company/notes/note path with a sniffed type", ctx do
    assert {:ok, att} =
             Attachments.attach(
               ctx.note,
               %{path: jpeg_file(), file_name: "photo.png"},
               ctx.company,
               ctx.admin
             )

    assert att.content_type == "image/jpeg"
    assert att.file_name == "photo.png"
    assert String.starts_with?(att.path, "#{ctx.company.id}/notes/#{ctx.note.id}/")
    assert String.ends_with?(att.path, ".jpg")
    assert File.exists?(Attachments.abs_path(att))
  end

  test "PDF is accepted", ctx do
    assert {:ok, %{content_type: "application/pdf"}} =
             Attachments.attach(
               ctx.note,
               %{path: pdf_file(), file_name: "cert.pdf"},
               ctx.company,
               ctx.admin
             )
  end

  test "a non-image named .jpg is refused and nothing is written", ctx do
    dir =
      Path.join([
        Application.get_env(:full_circle, :uploads_dir),
        ctx.company.id,
        "notes",
        ctx.note.id
      ])

    assert {:error, :unsupported_type} =
             Attachments.attach(
               ctx.note,
               %{path: text_file(), file_name: "x.jpg"},
               ctx.company,
               ctx.admin
             )

    refute File.exists?(dir) and File.ls!(dir) != []
    assert Repo.aggregate(NoteAttachment, :count) == 0
  end

  test "oversize is refused before reading", ctx do
    assert {:error, :too_large} =
             Attachments.attach(
               ctx.note,
               %{path: big_file(Attachments.max_bytes()), file_name: "big.jpg"},
               ctx.company,
               ctx.admin
             )
  end

  test "only someone who can edit the note may attach", ctx do
    clerk = user_with_role(ctx.company, ctx.admin, "clerk")

    assert :not_authorise =
             Attachments.attach(
               ctx.note,
               %{path: jpeg_file(), file_name: "a.jpg"},
               ctx.company,
               clerk
             )
  end

  test "remove hides it from the note and from download, but keeps the file", ctx do
    {:ok, att} =
      Attachments.attach(
        ctx.note,
        %{path: jpeg_file(), file_name: "a.jpg"},
        ctx.company,
        ctx.admin
      )

    assert {:ok, removed} = Attachments.remove(att, ctx.company, ctx.admin)
    assert removed.removed_at
    assert [] = Notes.get_note(ctx.note.id, ctx.company, ctx.admin).attachments
    assert File.exists?(Attachments.abs_path(att))
    # A removed file is usually the wrong one (someone's IC, a payslip);
    # an old link must not keep serving it.
    refute Attachments.get_readable(att.id, ctx.company, ctx.admin)
  end

  test "get_readable follows note visibility", ctx do
    hidden = note_fixture(ctx.company, ctx.admin, %{"visibility" => ["manager"]})

    {:ok, att} =
      Attachments.attach(hidden, %{path: jpeg_file(), file_name: "a.jpg"}, ctx.company, ctx.admin)

    clerk = user_with_role(ctx.company, ctx.admin, "clerk")
    refute Attachments.get_readable(att.id, ctx.company, clerk)
    refute Attachments.get_readable("not-a-uuid", ctx.company, ctx.admin)
  end

  describe "url/2 and kind/1" do
    test "every variant is served by the one download route for now", ctx do
      {:ok, att} =
        Attachments.attach(
          ctx.note,
          %{path: jpeg_file(), file_name: "a.jpg"},
          ctx.company,
          ctx.admin
        )

      original = "/companies/#{ctx.company.id}/note_attachments/#{att.id}"
      assert Attachments.url(att) == original
      assert Attachments.url(att, :original) == original
      # No generated thumbnails yet: :thumb falls back to the original file.
      assert Attachments.url(att, :thumb) == original
    end

    test "a PDF's thumb points at its rendered preview", ctx do
      {:ok, att} =
        Attachments.attach(
          ctx.note,
          %{path: pdf_file(), file_name: "c.pdf"},
          ctx.company,
          ctx.admin
        )

      assert Attachments.url(att, :thumb) ==
               "/companies/#{ctx.company.id}/note_attachments/#{att.id}?variant=thumb"
    end

    test "kind comes from the sniffed content type" do
      assert Attachments.kind(%NoteAttachment{content_type: "image/jpeg"}) == :image
      assert Attachments.kind(%NoteAttachment{content_type: "image/webp"}) == :image
      assert Attachments.kind(%NoteAttachment{content_type: "application/pdf"}) == :pdf
      assert Attachments.kind(%NoteAttachment{content_type: "application/zip"}) == :other
    end
  end

  describe "thumb_file/1" do
    @describetag :pdftoppm

    test "renders a PDF's first page to a JPEG once, then serves the cached copy", ctx do
      {:ok, att} =
        Attachments.attach(
          ctx.note,
          %{path: real_pdf_file(), file_name: "c.pdf"},
          ctx.company,
          ctx.admin
        )

      assert {:ok, path, "image/jpeg"} = Attachments.thumb_file(att)
      assert <<0xFF, 0xD8, 0xFF, _::binary>> = File.read!(path)
      assert path != Attachments.abs_path(att)

      %{mtime: first} = File.stat!(path)
      assert {:ok, ^path, "image/jpeg"} = Attachments.thumb_file(att)
      assert File.stat!(path).mtime == first
    end

    test "a PDF that cannot be rendered is an error, not a crash", ctx do
      {:ok, att} =
        Attachments.attach(
          ctx.note,
          %{path: pdf_file(), file_name: "bad.pdf"},
          ctx.company,
          ctx.admin
        )

      assert {:error, :no_preview} = Attachments.thumb_file(att)
    end

    test "an image's thumb is the image itself", ctx do
      {:ok, att} =
        Attachments.attach(
          ctx.note,
          %{path: jpeg_file(), file_name: "a.jpg"},
          ctx.company,
          ctx.admin
        )

      path = Attachments.abs_path(att)
      assert {:ok, ^path, "image/jpeg"} = Attachments.thumb_file(att)
    end
  end

  describe "photo_settings/1" do
    test "defaults to WhatsApp standard when the company has none", ctx do
      assert Attachments.photo_settings(ctx.company) == %{max_edge: 1600, quality: 75}
    end

    test "reads what was saved", ctx do
      {:ok, company} =
        FullCircle.Sys.update_company_settings(
          ctx.company,
          "photo",
          Attachments.clean_photo_settings(%{"max_edge" => "1920", "quality" => "85"})
        )

      assert Attachments.photo_settings(company) == %{max_edge: 1920, quality: 85}
    end

    test "clamps out-of-range and junk input" do
      assert Attachments.clean_photo_settings(%{"max_edge" => "99999", "quality" => "5"}) ==
               %{"max_edge" => 4096, "quality" => 50}

      assert Attachments.clean_photo_settings(%{"max_edge" => "10", "quality" => "100"}) ==
               %{"max_edge" => 640, "quality" => 95}

      assert Attachments.clean_photo_settings(%{"max_edge" => "abc", "quality" => ""}) ==
               %{"max_edge" => 1600, "quality" => 75}
    end
  end
end
