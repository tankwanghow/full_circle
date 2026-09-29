defmodule FullCircle.Notes.NoteVersion do
  @moduledoc """
  What a note said *before* an edit or delete superseded it.

  `written_by`/`written_at` are who wrote that version and when; `edited_by`
  and `inserted_at` are who replaced it and when.
  """
  use FullCircle.Schema
  import Ecto.Changeset

  alias FullCircle.UserAccounts.User

  schema "note_versions" do
    field :version, :integer
    field :title, :string
    field :body, :string
    field :subject_type, :string
    field :subject_id, :binary_id
    field :visibility, {:array, :string}
    field :written_at, :utc_datetime

    belongs_to :note, FullCircle.Notes.Note
    belongs_to :company, FullCircle.Sys.Company
    belongs_to :written_by, User
    belongs_to :edited_by, User

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def snapshot(note, version_no, editor) do
    change(%__MODULE__{}, %{
      note_id: note.id,
      company_id: note.company_id,
      version: version_no,
      title: note.title,
      body: note.body,
      subject_type: note.subject_type,
      subject_id: note.subject_id,
      visibility: note.visibility,
      written_by_id: note.updated_by_id,
      written_at: note.updated_at,
      edited_by_id: editor.id
    })
    |> unique_constraint([:note_id, :version])
  end
end
