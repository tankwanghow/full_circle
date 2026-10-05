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

  test "an image over the image limit is refused", ctx do
    assert {:error, {:too_large, 10_000_000}} =
             Attachments.attach(
               ctx.note,
               %{path: big_file(Attachments.max_bytes()), file_name: "big.jpg"},
               ctx.company,
               ctx.admin
             )
  end

  describe "recordings" do
    defp put(ctx, path, kind \\ nil) do
      Attachments.attach(
        ctx.note,
        %{path: path, file_name: "clip", kind: kind},
        ctx.company,
        ctx.admin
      )
    end

    test "an mp4 is a video, stored as .mp4", ctx do
      assert {:ok, att} = put(ctx, mp4_file(), "video")
      assert att.content_type == "video/mp4"
      assert String.ends_with?(att.path, ".mp4")
    end

    test "an M4A-branded mp4 is audio whatever the hint says", ctx do
      assert {:ok, att} = put(ctx, mp4_file("M4A "), "video")
      assert att.content_type == "audio/mp4"
      assert String.ends_with?(att.path, ".m4a")
    end

    test "a plain mp4 honours the audio hint (Chrome's audio/mp4)", ctx do
      assert {:ok, %{content_type: "audio/mp4"}} = put(ctx, mp4_file(), "audio")
    end

    test "webm follows the hint; no hint or a bad one makes it video", ctx do
      assert {:ok, %{content_type: "audio/webm", path: path}} = put(ctx, webm_file(), "audio")
      assert String.ends_with?(path, ".webm")
      assert {:ok, %{content_type: "video/webm"}} = put(ctx, webm_file(), "video")
      assert {:ok, %{content_type: "video/webm"}} = put(ctx, webm_file())
      assert {:ok, %{content_type: "video/webm"}} = put(ctx, webm_file(), "application")
    end

    test "ogg is always audio", ctx do
      assert {:ok, att} = put(ctx, ogg_file(), "video")
      assert att.content_type == "audio/ogg"
      assert String.ends_with?(att.path, ".ogg")
    end

    test "an mp3 (ID3 tag or bare frame) is audio/mpeg, stored as .mp3", ctx do
      assert {:ok, att} = put(ctx, mp3_file(:id3, 64), "video")
      assert att.content_type == "audio/mpeg"
      assert String.ends_with?(att.path, ".mp3")
      assert Attachments.kind(att) == :audio
      assert {:ok, %{content_type: "audio/mpeg"}} = put(ctx, mp3_file(:frame, 64))
      assert {:error, {:too_large, 5_000_000}} = put(ctx, mp3_file(:id3, 6_000_000))
    end

    test "a hint never makes a non-media file acceptable", ctx do
      assert {:error, :unsupported_type} = put(ctx, text_file(), "video")
      assert {:error, :unsupported_type} = put(ctx, text_file(), "audio")
    end

    # HEIC/AVIF photos are ISO-BMFF too: `ftyp` must not turn them into video.
    test "an HEIC or AVIF photo is not taken for a video", ctx do
      assert {:error, :unsupported_type} = put(ctx, mp4_file("heic"), "video")
      assert {:error, :unsupported_type} = put(ctx, mp4_file("mif1"), "video")
      assert {:error, :unsupported_type} = put(ctx, mp4_file("avif"), "video")
    end

    test "each kind has its own size cap", ctx do
      assert {:ok, %{content_type: "video/mp4"}} = put(ctx, mp4_file("isom", 12_000_000), "video")

      assert {:error, {:too_large, 15_000_000}} =
               put(ctx, mp4_file("isom", 15_000_001), "video")

      assert {:error, {:too_large, 5_000_000}} = put(ctx, webm_file(6_000_000), "audio")
      assert {:error, {:too_large, 10_000_000}} = put(ctx, big_file(11_000_000))
    end

    test "max_bytes/1 and max_seconds/1 per kind" do
      assert Attachments.max_bytes(:image) == 10_000_000
      assert Attachments.max_bytes(:pdf) == 10_000_000
      assert Attachments.max_bytes(:video) == 15_000_000
      assert Attachments.max_bytes(:audio) == 5_000_000
      assert Attachments.max_seconds(:video) == 60
      assert Attachments.max_seconds(:audio) == 180
    end

    test "recordings have no preview", ctx do
      {:ok, video} = put(ctx, mp4_file(), "video")
      {:ok, audio} = put(ctx, ogg_file())
      assert {:error, :no_preview} = Attachments.thumb_file(video)
      assert {:error, :no_preview} = Attachments.thumb_file(audio)
    end
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
      assert Attachments.kind(%NoteAttachment{content_type: "video/mp4"}) == :video
      assert Attachments.kind(%NoteAttachment{content_type: "video/webm"}) == :video
      assert Attachments.kind(%NoteAttachment{content_type: "audio/mp4"}) == :audio
      assert Attachments.kind(%NoteAttachment{content_type: "audio/ogg"}) == :audio
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
