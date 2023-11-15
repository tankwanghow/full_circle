defmodule FullCircle.WeightBridge.Weighing do
  use FullCircle.Schema
  import Ecto.Changeset
  import FullCircle.Helpers
  import FullCircleWeb.Gettext

  schema "weighings" do
    field :note_no, :string
    field :note_date, :date
    field :vehicle_no, :string
    field :good_name, :string
    field :note, :string
    field :gross, :integer, default: 0
    field :tare, :integer, default: 0

    belongs_to :company, FullCircle.Sys.Company

    field :nett, :integer, virtual: true

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(note, attrs) do
    note
    |> cast(attrs, [
      :note_no,
      :note_date,
      :vehicle_no,
      :good_name,
      :note,
      :gross,
      :tare,
      :company_id
    ])
    |> fill_today(:note_date)
    |> validate_required([
      :note_no,
      :note_date,
      :vehicle_no,
      :good_name,
      :gross,
      :tare
    ])
    |> validate_date(:note_date, days_before: 1)
    |> validate_date(:note_date, days_after: 1)
    |> to_upcase(:vehicle_no)
    |> to_upcase(:good_name)
    |> unsafe_validate_unique([:note_no, :company_id], FullCircle.Repo,
      message: gettext("note no already in company")
    )
    |> compute_nett()
  end

  def compute_nett(cs) do
    nett = fetch_field!(cs, :gross) - fetch_field!(cs, :tare)

    put_change(cs, :nett, nett)
  end
end
