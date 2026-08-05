defmodule FullCircle.CommandPalette.Hit do
  @moduledoc """
  One command-palette search result (document jump, v1).
  """

  @enforce_keys [:doc_type, :doc_id, :doc_no, :label, :path]
  defstruct [
    :doc_type,
    :doc_id,
    :doc_no,
    :doc_date,
    :contact_name,
    :label,
    :path
  ]

  @type t :: %__MODULE__{
          doc_type: String.t(),
          doc_id: Ecto.UUID.t(),
          doc_no: String.t(),
          doc_date: Date.t() | nil,
          contact_name: String.t() | nil,
          label: String.t(),
          path: String.t()
        }
end
