defmodule FullCircle.Tugas.DutyDocument do
  @moduledoc """
  A link from a duty to a real FullCircle document.

  `doc_id` deliberately carries no foreign key: the linkable types are a
  whitelist in `FullCircle.Tugas.document_types/0`, not a nullable column per
  document table. That keeps one duty able to point at many documents of
  different types without the schema growing a column every time a type is
  added — at the cost that the whitelist is the *only* thing keeping `doc_id`
  pointed at a row that exists, so `doc_type` is validated against it here.

  `doc_no` is a copy of the document's number at link time. It is display data
  for the trail, not a key; the document itself is found through `doc_id`.
  """
  use FullCircle.Schema
  import Ecto.Changeset

  schema "duty_documents" do
    field(:doc_type, :string)
    field(:doc_id, Ecto.UUID)
    field(:doc_no, :string)

    belongs_to(:duty, FullCircle.Tugas.Duty)
    belongs_to(:company, FullCircle.Sys.Company)
    belongs_to(:user, FullCircle.UserAccounts.User)

    timestamps(type: :utc_datetime)
  end

  def changeset(link, attrs) do
    link
    |> cast(attrs, [:doc_type, :doc_id, :doc_no, :duty_id, :company_id, :user_id])
    |> validate_required([:doc_type, :doc_id, :duty_id, :company_id])
    |> validate_inclusion(:doc_type, FullCircle.Tugas.document_types())
    |> unique_constraint([:duty_id, :doc_type, :doc_id],
      name: :duty_documents_duty_id_doc_type_doc_id_index,
      error_key: :doc_id,
      message: "already linked to this duty"
    )
    |> foreign_key_constraint(:duty_id)
    |> foreign_key_constraint(:company_id)
  end

  @doc "Short label used as the note on the linked/unlinked event."
  def label(%__MODULE__{doc_type: type, doc_no: nil}), do: type
  def label(%__MODULE__{doc_type: type, doc_no: no}), do: "#{type} #{no}"
end
