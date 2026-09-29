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
