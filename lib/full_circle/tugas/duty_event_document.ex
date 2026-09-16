defmodule FullCircle.Tugas.DutyEventDocument do
  @moduledoc """
  A file attached to a duty event.

  `content_type` is always sniffed from the bytes on the server. What a browser
  or a caller claims the type is never reaches this column — a `.pdf` filename
  on a PNG is common and harmless, but a claimed type is also the easy way to
  get a file served back as something it is not.

  `path` is relative to `:uploads_dir`, so moving the volume does not
  invalidate every row.
  """
  use FullCircle.Schema
  import Ecto.Changeset

  schema "duty_event_documents" do
    field(:file_name, :string)
    field(:content_type, :string)
    field(:file_size, :integer)
    field(:path, :string)

    belongs_to(:duty_event, FullCircle.Tugas.DutyEvent)
    belongs_to(:company, FullCircle.Sys.Company)

    timestamps(type: :utc_datetime)
  end

  def changeset(doc, attrs) do
    doc
    |> cast(attrs, [:file_name, :content_type, :file_size, :path, :duty_event_id, :company_id])
    |> validate_required([
      :file_name,
      :content_type,
      :file_size,
      :path,
      :duty_event_id,
      :company_id
    ])
    |> validate_inclusion(:content_type, FullCircle.Tugas.evidence_content_types())
    |> validate_length(:file_name, max: 255)
    |> foreign_key_constraint(:duty_event_id)
    |> foreign_key_constraint(:company_id)
  end
end
