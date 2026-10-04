defmodule FullCircle.Notes.NoteAttachment do
  use FullCircle.Schema
  import Ecto.Changeset

  schema "note_attachments" do
    field :file_name, :string
    field :content_type, :string
    field :byte_size, :integer
    field :path, :string
    field :removed_at, :utc_datetime

    belongs_to :company, FullCircle.Sys.Company
    # Exactly one of note / tray (the note_xor_tray check): a tray file is
    # waiting for its write box's Save.
    belongs_to :note, FullCircle.Notes.Note
    belongs_to :tray, FullCircle.Notes.NoteTray
    belongs_to :uploaded_by, FullCircle.UserAccounts.User
    belongs_to :removed_by, FullCircle.UserAccounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(att, attrs) do
    att
    |> cast(
      attrs,
      ~w(file_name content_type byte_size path company_id note_id tray_id uploaded_by_id)a
    )
    |> validate_required(~w(file_name content_type byte_size path company_id uploaded_by_id)a)
    |> foreign_key_constraint(:note_id)
    |> foreign_key_constraint(:tray_id)
    |> check_constraint(:note_id,
      name: :note_xor_tray,
      message: "must belong to a note or a tray"
    )
  end
end
