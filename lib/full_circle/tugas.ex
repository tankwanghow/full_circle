defmodule FullCircle.Tugas do
  @moduledoc """
  Duties: what has to get done, who moved it along, and what proves it.

  Three things hang off a duty:

    * **events** — an append-only trail (`progress`, `done`, `skip`, `linked`,
      `unlinked`, `end_series`). Events are the record; the duty row is just
      the current state.
    * **evidence** — files attached to an event.
    * **documents** — links to real FullCircle documents (`duty_documents`).
      One duty can point at many documents.

  Closing a cycle and spawning the next happen in one `Ecto.Multi`, so a duty
  series can never be left with zero live cycles or two.
  """
  import Ecto.Query, warn: false
  import FullCircle.Authorization

  alias Ecto.Multi
  alias FullCircle.Repo
  alias FullCircle.StdInterface
  alias FullCircle.Sys
  alias FullCircle.Tugas.Duty
  alias FullCircle.Tugas.DutyEvent

  @doc """
  Document types a duty may be linked to.

  Deliberately a whitelist: `duty_documents.doc_id` carries no foreign key, so
  this list is the only thing keeping the column pointed at real tables.
  """
  def document_types, do: ~w(Payment)

  def query(Duty, company, user) do
    from(d in Duty,
      join: com in subquery(Sys.user_company(company, user)),
      on: com.id == d.company_id,
      select: d
    )
  end

  def query(DutyEvent, company, user) do
    from(e in DutyEvent,
      join: com in subquery(Sys.user_company(company, user)),
      on: com.id == e.company_id,
      select: e
    )
  end

  def get_duty!(id, com, user),
    do: Repo.one!(from(d in query(Duty, com, user), where: d.id == ^id))

  def get_duty(id, com, user), do: Repo.one(from(d in query(Duty, com, user), where: d.id == ^id))

  # --- DUTIES ---------------------------------------------------------------

  def create_duty(attrs, com, user) do
    attrs =
      attrs
      |> FullCircle.Helpers.key_to_string()
      |> Map.put_new("series_id", Ecto.UUID.generate())
      |> Map.put("status", "active")

    StdInterface.create(Duty, "duty", attrs, com, user)
  end

  @doc """
  Edits the descriptive fields of a duty.

  Status is deliberately not editable here: a duty leaves `active` only through
  `complete_duty/4` or `skip_duty/4`, which also decide whether the next cycle
  is spawned. Letting a plain edit write `status` would strand a series with no
  live cycle.
  """
  def update_duty(%Duty{} = duty, attrs, com, user) do
    attrs =
      attrs
      |> FullCircle.Helpers.key_to_string()
      |> Map.drop(~w(status series_id series_ended_at company_id))

    with true <- can?(user, :update_duty, com) || :not_authorise do
      # Dropping the protected keys can leave nothing to write. Sys.Log
      # requires a non-blank delta, so an empty update would fail the
      # transaction on the log insert rather than being the no-op it is.
      if StdInterface.changeset(Duty, duty, attrs, com).changes == %{} do
        {:ok, duty}
      else
        StdInterface.update(Duty, "duty", duty, attrs, com, user)
      end
    end
  end

  # --- EVENTS ---------------------------------------------------------------

  @doc """
  Appends a `progress` note to a live duty.

  Progress on a closed duty is almost always a note meant for the cycle that
  has since been spawned, so it is refused rather than silently filed against
  history.
  """
  def add_progress(%Duty{} = duty, attrs, com, user) do
    with true <- can?(user, :create_duty_event, com) || :not_authorise,
         %Duty{status: "active"} <- get_duty(duty.id, com, user) do
      Multi.new()
      |> insert_event_multi(:duty_event, duty.id, "progress", note_of(attrs), com, user)
      |> Repo.transaction()
      |> case do
        {:ok, %{duty_event: event}} -> {:ok, event}
        {:error, _, failed_value, _} -> {:error, failed_value}
      end
    else
      :not_authorise -> :not_authorise
      _ -> {:error, :not_live}
    end
  end

  # Every event insert is paired with a Sys log entry, so the trail survives
  # even if the event row is later corrected or deleted inside the 48h window.
  defp insert_event_multi(multi, name, duty_id, action, note, com, user) do
    multi
    |> Multi.insert(
      name,
      DutyEvent.changeset(%DutyEvent{}, %{
        "action" => action,
        "note" => note,
        "duty_id" => duty_id,
        "company_id" => com.id,
        "user_id" => user.id
      })
    )
    |> Multi.insert("#{name}_log", fn %{^name => event} ->
      Sys.log_changeset(
        String.to_atom("create_duty_event_" <> action),
        event,
        %{"action" => action, "note" => note, "duty_id" => duty_id},
        com,
        user
      )
    end)
  end

  def list_duty_events(duty_id, com, user) do
    Repo.all(
      from(e in query(DutyEvent, com, user),
        where: e.duty_id == ^duty_id,
        order_by: [asc: e.inserted_at, asc: e.id]
      )
    )
  end

  defp note_of(attrs), do: attrs["note"] || attrs[:note]

  # --- CLOSING A CYCLE ------------------------------------------------------

  @doc """
  Marks the live cycle done and, unless the series has been ended, spawns the
  next one.

  Returns `{:ok, %{duty: closed, next_duty: next_or_nil}}`.
  """
  def complete_duty(duty_id, attrs, com, user),
    do: close_cycle(duty_id, "done", "done", :complete_duty, attrs, com, user)

  @doc """
  Marks the live cycle skipped and, unless the series has been ended, spawns
  the next one. A skipped cycle still advances the series — that is the whole
  point of skipping rather than deleting.
  """
  def skip_duty(duty_id, attrs, com, user),
    do: close_cycle(duty_id, "skipped", "skip", :skip_duty, attrs, com, user)

  defp close_cycle(duty_id, status, action, auth_action, attrs, com, user) do
    note = note_of(attrs)

    with true <- can?(user, auth_action, com) || :not_authorise do
      Multi.new()
      |> Multi.run(:live_duty, fn repo, _ -> lock_live_duty(repo, duty_id, com) end)
      # The close must be written before the spawn, or the partial unique index
      # on (series_id) WHERE status='active' would see two live cycles at once.
      |> Multi.update(:duty, fn %{live_duty: duty} ->
        Duty.changeset(duty, %{"status" => status})
      end)
      |> Multi.insert("#{auth_action}_log", fn %{duty: duty} ->
        Sys.log_changeset(auth_action, duty, %{"status" => status, "note" => note}, com, user)
      end)
      |> insert_event_multi(:duty_event, duty_id, action, note, com, user)
      |> Multi.run(:next_duty, fn repo, %{live_duty: duty} -> spawn_next(repo, duty) end)
      |> Repo.transaction()
      |> case do
        {:ok, changes} -> {:ok, changes}
        {:error, :live_duty, :not_live, _} -> {:error, :not_live}
        {:error, _, failed_value, _} -> {:error, failed_value}
      end
    end
  end

  # SELECT ... FOR UPDATE inside the transaction: two concurrent closes of the
  # same cycle serialise here, and whichever arrives second re-reads a row that
  # is no longer active and gets {:error, :not_live} instead of double-closing
  # and double-spawning.
  #
  # Scoped by company_id rather than by the user_company subquery because
  # Postgres refuses FOR UPDATE on a query that joins a subquery. Membership is
  # already established by the can?/3 check above, which reports "disable" for
  # a user with no row in this company.
  defp lock_live_duty(repo, duty_id, com) do
    from(d in Duty,
      where: d.id == ^duty_id and d.company_id == ^com.id,
      lock: "FOR UPDATE"
    )
    |> repo.one()
    |> case do
      %Duty{status: "active"} = duty -> {:ok, duty}
      _ -> {:error, :not_live}
    end
  end

  defp spawn_next(_repo, %Duty{recur_unit: nil}), do: {:ok, nil}
  defp spawn_next(_repo, %Duty{series_ended_at: %DateTime{}}), do: {:ok, nil}

  defp spawn_next(repo, %Duty{} = duty) do
    repo.insert(
      Duty.changeset(%Duty{}, %{
        "title" => duty.title,
        "descriptions" => duty.descriptions,
        "due_date" => Duty.next_due_date(duty.due_date, duty.recur_unit, duty.recur_every),
        "status" => "active",
        "series_id" => duty.series_id,
        "recur_unit" => duty.recur_unit,
        "recur_every" => duty.recur_every,
        "company_id" => duty.company_id
      })
    )
  end

  @doc """
  Stops a series from ever spawning again.

  Deliberately does not close the live cycle: the work that is already due
  still has to be finished or skipped. Every row of the series is stamped so
  the fact is visible from any cycle, not only the last one.
  """
  def end_series(%Duty{} = duty, com, user) do
    with true <- can?(user, :end_duty_series, com) || :not_authorise,
         %Duty{} = duty <- get_duty(duty.id, com, user) do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      Multi.new()
      |> Multi.update_all(
        :series,
        from(d in Duty,
          where:
            d.series_id == ^duty.series_id and d.company_id == ^com.id and
              is_nil(d.series_ended_at)
        ),
        set: [series_ended_at: now, updated_at: now]
      )
      |> insert_event_multi(:duty_event, duty.id, "end_series", nil, com, user)
      |> Multi.insert("end_duty_series_log", fn _ ->
        Sys.log_changeset(
          :end_duty_series,
          duty,
          %{"series_id" => duty.series_id, "series_ended_at" => now},
          com,
          user
        )
      end)
      |> Multi.run(:duty, fn repo, _ -> {:ok, repo.get!(Duty, duty.id)} end)
      |> Repo.transaction()
      |> case do
        {:ok, changes} -> {:ok, changes}
        {:error, _, failed_value, _} -> {:error, failed_value}
      end
    else
      :not_authorise -> :not_authorise
      nil -> {:error, :not_found}
    end
  end
end
