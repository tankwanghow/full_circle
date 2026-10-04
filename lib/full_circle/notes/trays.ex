defmodule FullCircle.Notes.Trays do
  @moduledoc """
  A write box's files before Save. The box makes a random tray id when it
  opens; the first upload (desktop or phone) creates the `note_trays` row for
  that user. Save claims the tray inside the note's own transaction
  (`claim/5`), Cancel hard-deletes its files (they never belonged to a note,
  so there is no history to keep). A tray belongs to one user in one company:
  any other user's id is simply "not found". Contract: `.claude/skills/notes.md`.
  """
  import Ecto.Query, warn: false

  alias FullCircle.Repo
  alias FullCircle.Notes.{Attachments, NoteAttachment, NoteTray}

  def open(id, company, user) do
    with {:ok, id} <- Ecto.UUID.cast(id) do
      Repo.insert(%NoteTray{id: id, company_id: company.id, user_id: user.id},
        on_conflict: :nothing,
        conflict_target: :id
      )

      get(id, company, user)
    else
      :error -> {:error, :not_found}
    end
  end

  def get(id, company, user) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %NoteTray{} = tray <-
           Repo.get_by(NoteTray, id: id, company_id: company.id, user_id: user.id) do
      {:ok, tray}
    else
      _ -> {:error, :not_found}
    end
  end

  def list(tray_id, company, user) do
    case get(tray_id, company, user) do
      {:ok, tray} ->
        from(a in NoteAttachment, where: a.tray_id == ^tray.id, order_by: [asc: a.inserted_at])
        |> Repo.all()

      _ ->
        []
    end
  end

  def discard_file(att_id, tray_id, company, user) do
    with {:ok, tray} <- get(tray_id, company, user),
         {:ok, att_id} <- Ecto.UUID.cast(att_id),
         %NoteAttachment{} = att <- Repo.get_by(NoteAttachment, id: att_id, tray_id: tray.id) do
      delete_files([att])
    end

    :ok
  end

  def cancel(tray_id, company, user) do
    with {:ok, tray} <- get(tray_id, company, user) do
      delete_files(Repo.all(from a in NoteAttachment, where: a.tray_id == ^tray.id))

      tray
      |> Ecto.Changeset.change(closed_at: DateTime.utc_now(:second))
      |> Repo.update!()
    end

    :ok
  end

  # Rows first, then files: a crash between leaves orphan files (pruned with
  # their folder), never rows pointing at nothing.
  defp delete_files([]), do: :ok

  defp delete_files(atts) do
    Repo.delete_all(from a in NoteAttachment, where: a.id in ^Enum.map(atts, & &1.id))
    Enum.each(atts, &File.rm(Attachments.abs_path(&1)))
  end
end
