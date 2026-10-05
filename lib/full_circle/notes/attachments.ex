defmodule FullCircle.Notes.Attachments do
  @moduledoc """
  Files on a note. Type is sniffed from magic bytes — the client's claim never
  reaches the column, because it decides how the file is served back. Size is
  checked with `File.stat/1` before any read. Removing hides a file from the
  note and from download, but keeps it on disk: history may still name it.
  """
  import Ecto.Query, warn: false
  require Logger

  alias FullCircle.{Notes, Repo}
  alias FullCircle.Notes.{Note, NoteAttachment, NoteTray, Trays}

  @max_bytes 10_000_000
  @content_types ~w(image/jpeg image/png image/webp application/pdf
                    video/mp4 video/webm audio/mp4 audio/webm audio/ogg audio/mpeg)

  # Recordings are made on the phone page (note_record.js) at 480p ~1 Mbit/s
  # or 64 kbit/s audio; the caps are those rates times the time limits, plus
  # encoder overshoot. Desktop 📎 media files get the same limits, checked in
  # the browser before upload (note_attach.js). The size cap is what protects
  # the disk; nothing here reads a file's duration.
  @max_bytes_by_kind %{video: 15_000_000, audio: 5_000_000}
  @max_seconds %{video: 60, audio: 180}

  @doc "The image/PDF limit. Recordings have their own: `max_bytes/1`."
  def max_bytes, do: @max_bytes

  def max_bytes(kind), do: Map.get(@max_bytes_by_kind, kind, @max_bytes)

  @doc "How long the in-app recorder runs before it stops itself."
  def max_seconds(kind) when kind in [:video, :audio], do: Map.fetch!(@max_seconds, kind)

  def content_types, do: @content_types

  # Photos are shrunk in the browser before upload (`downscale` in
  # note_attach.js); these are its knobs, per company, in
  # `companies.settings["photo"]`. Default = WhatsApp "standard" quality.
  @photo_defaults %{"max_edge" => 1600, "quality" => 75}
  @photo_ranges %{"max_edge" => 640..4096, "quality" => 50..95}

  @doc """
  The company's photo downscale settings: `%{max_edge: px, quality: 50..95}`.
  `quality` is a JPEG percentage; the browser divides it by 100.
  """
  def photo_settings(company) do
    saved = FullCircle.Sys.get_company_settings(company, "photo")
    %{"max_edge" => edge, "quality" => q} = clean_photo_settings(saved)
    %{max_edge: edge, quality: q}
  end

  @doc "Form params (or a stored map) → the map to store, clamped to sane ranges."
  def clean_photo_settings(params) do
    Map.new(@photo_defaults, fn {key, default} ->
      lo..hi//_ = Map.fetch!(@photo_ranges, key)

      value =
        case to_int(params[key]) do
          nil -> default
          n -> n |> max(lo) |> min(hi)
        end

      {key, value}
    end)
  end

  defp to_int(n) when is_integer(n), do: n

  defp to_int(s) when is_binary(s) do
    case Integer.parse(String.trim(s)) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp to_int(_), do: nil

  @doc "PubSub topic for \"a file landed\" in this company (see FullCircleWeb.NoteFiles)."
  def topic(company_id), do: "note_files:#{company_id}"

  def abs_path(%NoteAttachment{path: rel}), do: Path.join(uploads_dir(), rel)

  @doc """
  Where a page links or points an `<img>` for this file. Templates must go
  through this rather than building the path, so that renditions change only
  here.

  `:thumb` is a PDF's rendered first page (`thumb_file/1`); for images it is
  the original, which is already downscaled on upload.
  """
  def url(att, variant \\ :original)

  def url(%NoteAttachment{} = att, :original),
    do: "/companies/#{att.company_id}/note_attachments/#{att.id}"

  def url(%NoteAttachment{} = att, :thumb) do
    case kind(att) do
      :pdf -> url(att, :original) <> "?variant=thumb"
      _ -> url(att, :original)
    end
  end

  @thumb_px 480
  @render_timeout_s "10"

  @doc """
  The file to serve for `url(att, :thumb)`: `{:ok, abs_path, content_type}`.

  A PDF's first page is rendered by `pdftoppm` (poppler-utils, in the prod
  image) the first time it is asked for, and cached next to the file as
  `<file>.thumb.jpg`. Rendering is killed after #{@render_timeout_s}s, writes
  to a temp name and renames, so a hostile PDF cannot hang a request and two
  first views cannot clash. A PDF that will not render (encrypted, corrupt,
  no pdftoppm) gives `{:error, :no_preview}` and is remembered, so it is not
  retried on every feed load; the page then shows the plain PDF tile.
  """
  def thumb_file(%NoteAttachment{} = att) do
    case kind(att) do
      :image -> {:ok, abs_path(att), att.content_type}
      :pdf -> pdf_thumb(att)
      # No poster frames: that would need ffmpeg on the server.
      _video_audio_other -> {:error, :no_preview}
    end
  end

  defp pdf_thumb(att) do
    dest = abs_path(att) <> ".thumb.jpg"
    failed = abs_path(att) <> ".thumb.failed"

    cond do
      File.exists?(dest) -> {:ok, dest, "image/jpeg"}
      File.exists?(failed) -> {:error, :no_preview}
      true -> render_pdf(abs_path(att), dest, failed)
    end
  end

  defp render_pdf(src, dest, failed) do
    tmp_base = "#{dest}.tmp#{System.unique_integer([:positive])}"

    args =
      [@render_timeout_s, "pdftoppm", "-f", "1", "-l", "1", "-singlefile", "-jpeg"] ++
        ["-scale-to", "#{@thumb_px}", src, tmp_base]

    result =
      try do
        System.cmd("timeout", args, stderr_to_stdout: true)
      rescue
        # timeout/pdftoppm not installed
        e in ErlangError -> {Exception.message(e), :not_run}
      end

    with {_out, 0} <- result,
         :ok <- File.rename(tmp_base <> ".jpg", dest) do
      {:ok, dest, "image/jpeg"}
    else
      other ->
        File.rm(tmp_base <> ".jpg")
        Logger.warning("note PDF preview failed for #{src}: #{inspect(other)}")
        File.write(failed, "")
        {:error, :no_preview}
    end
  end

  @doc """
  What kind of file this is, from its sniffed content type. Pages choose how
  to show a file from this, not from content-type strings.
  """
  def kind(%NoteAttachment{content_type: ct}), do: kind_of(ct)

  defp kind_of("image/" <> _), do: :image
  defp kind_of("application/pdf"), do: :pdf
  defp kind_of("video/" <> _), do: :video
  defp kind_of("audio/" <> _), do: :audio
  defp kind_of(_), do: :other

  def attach(%Note{} = note, upload, company, user) do
    with %Note{} = note <- Notes.get_note(note.id, company, user) || {:error, :note_not_found},
         true <- Notes.may_edit?(note, user, Notes.rights(company, user)) || :not_authorise do
      store({:note, note}, upload, company, user)
    end
  end

  @doc """
  Adds a file to the caller's tray. A tray already saved follows to its note
  (a phone still sending after the desktop pressed Save); a cancelled one is
  `{:error, :tray_closed}`.
  """
  def attach_to_tray(tray_id, upload, company, user) do
    case Trays.get(tray_id, company, user) do
      {:ok, tray} -> store_in_tray(tray, upload, company, user)
      error -> error
    end
  end

  @doc """
  `tray` is the caller's tray as last read; it may have been saved or
  cancelled since (a phone upload racing the desktop's Save). The insert
  re-reads it under a row lock (`FOR SHARE` against `Trays.claim/5`'s and
  `Trays.cancel/3`'s `FOR UPDATE`), so the file lands in the open tray, on
  the saved note, or is refused — never left in a closed tray.
  """
  def store_in_tray(%NoteTray{} = tray, upload, company, user) do
    case store({:tray, tray}, upload, company, user) do
      {:error, {:follow, note_id}} -> attach(%Note{id: note_id}, upload, company, user)
      other -> other
    end
  end

  defp store(owner, upload, company, user) do
    src = upload[:path] || upload["path"]
    file_name = upload[:file_name] || upload["file_name"] || "file"
    hint = upload[:kind] || upload["kind"]

    # Sniff first (32 bytes), then size: the cap depends on the kind.
    with {:ok, content_type} <- sniff(src, hint),
         {:ok, size} <- assert_size(src, max_bytes(kind_of(content_type))) do
      # file_name is display only; cap it under the varchar(255) column.
      name = file_name |> Path.basename() |> String.slice(0, 200)
      write(owner, src, name, size, content_type, company, user)
    end
  end

  def remove(%NoteAttachment{} = att, company, user) do
    with %Note{} = note <- Notes.get_note(att.note_id, company, user) || {:error, :not_found},
         true <- Notes.may_edit?(note, user, Notes.rights(company, user)) || :not_authorise do
      att
      |> Ecto.Changeset.change(removed_at: DateTime.utc_now(:second), removed_by_id: user.id)
      |> Repo.update()
    end
  end

  def get_readable(id, company, user) do
    with {:ok, id} <- Ecto.UUID.cast(id) do
      from(a in NoteAttachment,
        left_join: n in subquery(Notes.visible_to(company, user)),
        on: n.id == a.note_id,
        # A tray file (not saved yet) is its owner's alone: the write box
        # shows it as a thumbnail before Save.
        left_join: t in NoteTray,
        on: t.id == a.tray_id and t.company_id == ^company.id and t.user_id == ^user.id,
        # A removed file stays on disk for history, but is usually the wrong
        # upload (an IC, a payslip) — an old link must not keep serving it.
        where: a.id == ^id and is_nil(a.removed_at),
        where: not is_nil(n.id) or not is_nil(t.id)
      )
      |> Repo.one()
    else
      _ -> nil
    end
  end

  defp assert_size(src, max) do
    case File.stat(src) do
      {:ok, %{size: size}} when size <= max -> {:ok, size}
      {:ok, _} -> {:error, {:too_large, max}}
      {:error, _} -> {:error, :not_found}
    end
  end

  # HEIC/AVIF photos are ISO-BMFF (`ftyp`) like mp4; they are not recordings.
  @image_brands ~w(heic heix hevc hevx heim heis mif1 msf1 avif avis)

  # `hint` is the recorder's `kind` form field. It only picks between two
  # inert media types for a container already verified here (mp4 and webm
  # carry either); it never makes another file acceptable.
  defp sniff(src, hint) do
    case File.open(src || "", [:read, :binary], &IO.binread(&1, 32)) do
      {:ok, <<0xFF, 0xD8, 0xFF, _::binary>>} ->
        {:ok, "image/jpeg"}

      {:ok, <<0x89, "PNG\r\n", 0x1A, 0x0A, _::binary>>} ->
        {:ok, "image/png"}

      {:ok, <<"RIFF", _::binary-size(4), "WEBP", _::binary>>} ->
        {:ok, "image/webp"}

      {:ok, <<"%PDF-", _::binary>>} ->
        {:ok, "application/pdf"}

      {:ok, <<_::binary-size(4), "ftyp", "M4A ", _::binary>>} ->
        {:ok, "audio/mp4"}

      {:ok, <<_::binary-size(4), "ftyp", brand::binary-size(4), _::binary>>}
      when brand not in @image_brands ->
        {:ok, media(hint) <> "/mp4"}

      {:ok, <<0x1A, 0x45, 0xDF, 0xA3, _::binary>>} ->
        {:ok, media(hint) <> "/webm"}

      {:ok, <<"OggS", _::binary>>} ->
        {:ok, "audio/ogg"}

      # mp3: an ID3 tag, or a bare MPEG audio frame (11 sync bits, layer not
      # reserved). JPEG's FF D8 fails the sync bits, so it never lands here.
      {:ok, <<"ID3", _::binary>>} ->
        {:ok, "audio/mpeg"}

      {:ok, <<0xFF, b, _::binary>>}
      when Bitwise.band(b, 0xE0) == 0xE0 and Bitwise.band(b, 0x06) != 0 ->
        {:ok, "audio/mpeg"}

      {:ok, _} ->
        {:error, :unsupported_type}

      {:error, _} ->
        {:error, :not_found}
    end
  end

  defp media("audio"), do: "audio"
  defp media(_), do: "video"

  defp write(owner, src, file_name, size, content_type, company, user) do
    {dir, owner_attrs, target} =
      case owner do
        {:note, note} -> {[note.id], %{note_id: note.id}, {:note, note.id}}
        {:tray, tray} -> {["tray", tray.id], %{tray_id: tray.id}, {:tray, tray.id}}
      end

    rel = Path.join([company.id, "notes"] ++ dir ++ [Ecto.UUID.generate() <> ext(content_type)])
    abs = Path.join(uploads_dir(), rel)
    File.mkdir_p!(Path.dirname(abs))
    File.cp!(src, abs)

    %NoteAttachment{}
    |> NoteAttachment.changeset(
      Map.merge(owner_attrs, %{
        file_name: file_name,
        content_type: content_type,
        byte_size: size,
        path: rel,
        company_id: company.id,
        uploaded_by_id: user.id
      })
    )
    |> insert(owner)
    |> case do
      {:ok, att} ->
        Phoenix.PubSub.broadcast(
          FullCircle.PubSub,
          topic(company.id),
          {:note_files_changed, target}
        )

        {:ok, att}

      {:error, cs} ->
        # Without its row the file is garbage nothing will ever find.
        File.rm(abs)
        {:error, cs}
    end
  rescue
    e in [File.Error, File.CopyError] ->
      Logger.error("note attachment copy failed: #{Exception.message(e)}")
      {:error, :copy_failed}
  end

  defp insert(changeset, {:note, _note}), do: Repo.insert(changeset)

  defp insert(changeset, {:tray, %NoteTray{id: id}}) do
    Repo.transaction(fn ->
      case Repo.one(from t in NoteTray, where: t.id == ^id, lock: "FOR SHARE") do
        %NoteTray{closed_at: nil} ->
          case Repo.insert(changeset) do
            {:ok, att} -> att
            {:error, cs} -> Repo.rollback(cs)
          end

        %NoteTray{note_id: nil} ->
          Repo.rollback(:tray_closed)

        %NoteTray{note_id: note_id} ->
          Repo.rollback({:follow, note_id})

        nil ->
          Repo.rollback(:not_found)
      end
    end)
  end

  defp ext("image/jpeg"), do: ".jpg"
  defp ext("image/png"), do: ".png"
  defp ext("image/webp"), do: ".webp"
  defp ext("application/pdf"), do: ".pdf"
  defp ext("video/mp4"), do: ".mp4"
  defp ext("audio/mp4"), do: ".m4a"
  defp ext("video/webm"), do: ".webm"
  defp ext("audio/webm"), do: ".webm"
  defp ext("audio/ogg"), do: ".ogg"
  defp ext("audio/mpeg"), do: ".mp3"

  def uploads_dir, do: Application.get_env(:full_circle, :uploads_dir)
end
