defmodule FullCircle.Tugas.DutyEvent do
  @moduledoc """
  One entry in a duty's append-only trail.

  Events are the record of what happened; the `status` column on `duties` is
  only the current state derived from them. Nothing here is edited after the
  fact except through the 48-hour correction window, and `end_series` is
  recorded against the cycle that was live when the series was stopped.
  """
  use FullCircle.Schema
  import Ecto.Changeset

  @actions ~w(progress done skip linked unlinked end_series)

  def actions, do: @actions

  schema "duty_events" do
    field(:action, :string)
    field(:note, :string)

    belongs_to(:duty, FullCircle.Tugas.Duty)
    belongs_to(:company, FullCircle.Sys.Company)
    belongs_to(:user, FullCircle.UserAccounts.User)

    # Microsecond precision, unlike the rest of the app: several events can be
    # written inside one transaction (close + spawn, link + event), and at
    # second precision the trail comes back in an arbitrary order because the
    # only tiebreaker left is a random UUID.
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:action, :note, :duty_id, :company_id, :user_id])
    |> validate_required([:action, :duty_id, :company_id])
    |> validate_inclusion(:action, @actions)
    |> foreign_key_constraint(:duty_id)
    |> foreign_key_constraint(:company_id)
  end
end
