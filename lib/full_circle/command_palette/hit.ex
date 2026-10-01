defmodule FullCircle.CommandPalette.Hit do
  @moduledoc """
  One command-palette result: an existing document or a create action.
  """

  @enforce_keys [:kind, :label, :path]
  defstruct [
    :kind,
    :doc_type,
    :doc_id,
    :doc_no,
    :doc_date,
    :contact_name,
    :good_name,
    :bank_name,
    # Preformatted second line (notes); nil → built from the fields above
    :subtitle,
    :label,
    :path
  ]

  @type kind :: :document | :action | :contact | :recent | :note | :note_search

  @type t :: %__MODULE__{
          kind: kind(),
          doc_type: String.t() | nil,
          doc_id: Ecto.UUID.t() | nil,
          doc_no: String.t() | nil,
          doc_date: Date.t() | nil,
          contact_name: String.t() | nil,
          good_name: String.t() | nil,
          bank_name: String.t() | nil,
          subtitle: String.t() | nil,
          label: String.t(),
          path: String.t()
        }
end
