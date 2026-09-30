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
  alias FullCircle.Notes.{Note, NoteAttachment}

  @max_bytes 10_000_000
  @content_types ~w(image/jpeg image/png image/webp application/pdf)

  def max_bytes, do: @max_bytes
  def content_types, do: @content_types

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
      :other -> {:error, :no_preview}
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
  to show a file from this, not from content-type strings. `:video` and
  `:audio` join here when those types are allowed.
  """
  def kind(%NoteAttachment{content_type: "image/" <> _}), do: :image
  def kind(%NoteAttachment{content_type: "application/pdf"}), do: :pdf
  def kind(%NoteAttachment{}), do: :other

  def attach(%Note{} = note, upload, company, user) do
    src = upload[:path] || upload["path"]
    file_name = upload[:file_name] || upload["file_name"] || "file"

    with %Note{} = note <- Notes.get_note(note.id, company, user) || {:error, :note_not_found},
         true <- Notes.may_edit?(note, user, Notes.rights(company, user)) || :not_authorise,
         {:ok, size} <- assert_size(src),
         {:ok, content_type} <- sniff(src) do
      # file_name is display only; cap it under the varchar(255) column.
      name = file_name |> Path.basename() |> String.slice(0, 200)
      write(note, src, name, size, content_type, company, user)
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
        join: n in subquery(Notes.visible_to(company, user)),
        on: n.id == a.note_id,
        # A removed file stays on disk for history, but is usually the wrong
        # upload (an IC, a payslip) — an old link must not keep serving it.
        where: a.id == ^id and is_nil(a.removed_at)
      )
      |> Repo.one()
    else
      _ -> nil
    end
  end

  defp assert_size(src) do
    case File.stat(src || "") do
      {:ok, %{size: size}} when size <= @max_bytes -> {:ok, size}
      {:ok, _} -> {:error, :too_large}
      {:error, _} -> {:error, :not_found}
    end
  end

  defp sniff(src) do
    case File.open(src, [:read, :binary], &IO.binread(&1, 16)) do
      {:ok, <<0xFF, 0xD8, 0xFF, _::binary>>} -> {:ok, "image/jpeg"}
      {:ok, <<0x89, "PNG\r\n", 0x1A, 0x0A, _::binary>>} -> {:ok, "image/png"}
      {:ok, <<"RIFF", _::binary-size(4), "WEBP", _::binary>>} -> {:ok, "image/webp"}
      {:ok, <<"%PDF-", _::binary>>} -> {:ok, "application/pdf"}
      {:ok, _} -> {:error, :unsupported_type}
      {:error, _} -> {:error, :not_found}
    end
  end

  defp write(note, src, file_name, size, content_type, company, user) do
    rel = Path.join([company.id, "notes", note.id, Ecto.UUID.generate() <> ext(content_type)])
    abs = Path.join(uploads_dir(), rel)
    File.mkdir_p!(Path.dirname(abs))
    File.cp!(src, abs)

    %NoteAttachment{}
    |> NoteAttachment.changeset(%{
      file_name: file_name,
      content_type: content_type,
      byte_size: size,
      path: rel,
      company_id: company.id,
      note_id: note.id,
      uploaded_by_id: user.id
    })
    |> Repo.insert()
    |> case do
      {:ok, att} ->
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

  defp ext("image/jpeg"), do: ".jpg"
  defp ext("image/png"), do: ".png"
  defp ext("image/webp"), do: ".webp"
  defp ext("application/pdf"), do: ".pdf"

  defp uploads_dir, do: Application.get_env(:full_circle, :uploads_dir)
end
