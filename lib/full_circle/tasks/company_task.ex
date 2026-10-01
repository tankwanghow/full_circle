defmodule FullCircle.Tasks.CompanyTask do
  @moduledoc """
  One cycle of a task (reminder or todo). A repeating task is a series of rows
  sharing `series_id`; closing one inserts the next (see `FullCircle.Tasks`).

  Named `CompanyTask`, not `Task`, so it never shadows `Elixir.Task`.
  `visibility` works exactly like `notes.visibility`.
  """
  use FullCircle.Schema
  import Ecto.Changeset

  alias FullCircle.Notes.Note
  alias FullCircle.UserAccounts.User

  @units ~w(day week month year)

  schema "tasks" do
    field :series_id, :binary_id
    field :title, :string
    field :descriptions, :string
    field :due_date, :date
    field :recur_unit, :string
    field :recur_every, :integer
    field :reminder_before_days, :integer
    field :documents_needed, :string
    field :visibility, {:array, :string}
    field :status, :string, default: "open"
    field :closed_at, :utc_datetime
    field :lock_version, :integer, default: 0
    field :deleted_at, :utc_datetime

    belongs_to :company, FullCircle.Sys.Company
    belongs_to :assignee, User
    belongs_to :closed_by, User
    belongs_to :creator, User
    belongs_to :deleted_by, User

    timestamps(type: :utc_datetime)
  end

  @castable ~w(title descriptions due_date recur_unit recur_every reminder_before_days
               documents_needed assignee_id visibility)a

  def recur_units, do: @units

  def changeset(task, attrs) do
    task
    |> cast(attrs, @castable)
    |> validate_required([:title])
    |> validate_length(:title, max: 120)
    |> validate_inclusion(:recur_unit, @units)
    |> validate_number(:recur_every, greater_than_or_equal_to: 1)
    |> validate_number(:reminder_before_days, greater_than_or_equal_to: 0)
    |> validate_recurrence()
    |> validate_visibility()
    |> check_constraint(:recur_unit, name: :tasks_recurrence)
    |> check_constraint(:visibility, name: :tasks_visibility_not_empty)
  end

  def close_changeset(task, kind, user) when kind in [:done, :skipped] do
    change(task,
      status: Atom.to_string(kind),
      closed_at: DateTime.utc_now(:second),
      closed_by_id: user.id
    )
  end

  # The form always sends an "every" box; without a unit it means nothing.
  defp validate_recurrence(cs) do
    if is_nil(get_field(cs, :recur_unit)) do
      put_change(cs, :recur_every, nil)
    else
      cs = validate_required(cs, [:recur_every])

      if is_nil(get_field(cs, :due_date)),
        do: add_error(cs, :due_date, "is needed to repeat"),
        else: cs
    end
  end

  defp validate_visibility(cs) do
    case get_field(cs, :visibility) do
      nil ->
        cs

      [] ->
        add_error(cs, :visibility, "use nil for everyone")

      _ ->
        validate_subset(cs, :visibility, Note.visibility_values(),
          message: "has an invalid entry"
        )
    end
  end
end
