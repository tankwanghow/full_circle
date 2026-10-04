defmodule FullCircle.Notes.NoteTray do
  @moduledoc """
  A write box's files before Save (see `FullCircle.Notes.Trays`). Open while
  `closed_at` is nil; Save sets `note_id` and `closed_at`, Cancel only
  `closed_at`.
  """
  use FullCircle.Schema

  schema "note_trays" do
    field :closed_at, :utc_datetime

    belongs_to :company, FullCircle.Sys.Company
    belongs_to :user, FullCircle.UserAccounts.User
    belongs_to :note, FullCircle.Notes.Note

    timestamps(type: :utc_datetime)
  end
end
