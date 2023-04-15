defmodule FullCircle.Sys.GaplessDocId do
  use Ecto.Schema
  import Ecto.Changeset

  schema "gapless_doc_ids" do
    field :doc_type, :string
    field :current, :integer, default: 0
    belongs_to :company, FullCircle.Sys.Company
  end

  @doc false
  def changeset(gapless_doc_id, attrs) do
    gapless_doc_id
    |> cast(attrs, [:doc_type, :current, :company_id])
    |> validate_required([:doc_type, :current, :company_id])
  end
end
