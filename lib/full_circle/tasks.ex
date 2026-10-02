defmodule FullCircle.Tasks do
  @moduledoc """
  Tasks: recurring duties, job tracking and todos. One `tasks` row per cycle.

  Every read goes through `visible_to/3`. Progress notes are Notes about the
  task (`subject_type "Task"`). See `.claude/skills/tasks.md`.
  """
  import Ecto.Query, warn: false
  import FullCircle.Authorization

  alias Ecto.Multi
  alias FullCircle.{Linkable, Notes, Repo, Sys}
  alias FullCircle.Linkable.RecordLink
  alias FullCircle.Sys.CompanyUser
  alias FullCircle.Tasks.CompanyTask
  alias FullCircle.UserAccounts.User

  # Roles holding :create_task — the only ones that can close a task, so the
  # only ones worth assigning one to.
  @closers ~w(admin manager supervisor cashier clerk)

  def topic(company_id), do: "#{company_id}_tasks"

  defp broadcast(company) do
    Phoenix.PubSub.broadcast(FullCircle.PubSub, topic(company.id), {:tasks_changed, company.id})
  end

  # --- visibility -----------------------------------------------------------

  def visible_to(query \\ CompanyTask, company, user) do
    if can?(user, :view_tasks, company) do
      role = user_role_in_company(user.id, company.id)

      base =
        from(t in query,
          join: c in subquery(Sys.user_company(company, user)),
          on: c.id == t.company_id,
          where: is_nil(t.deleted_at)
        )

      if role == "admin" do
        base
      else
        from(t in base,
          where:
            is_nil(t.visibility) or ^role in t.visibility or t.creator_id == ^user.id or
              t.assignee_id == ^user.id
        )
      end
    else
      from(t in query, where: false)
    end
  end

  @doc "Looked up once per page; pair with the `may_*?` checks for visible tasks."
  def rights(company, user) do
    %{
      create: can?(user, :create_task, company),
      edit_others: can?(user, :edit_others_task, company)
    }
  end

  def may_edit?(%CompanyTask{creator_id: c}, user, r),
    do: (c == user.id and r.create) or r.edit_others

  def may_close?(%CompanyTask{}, _user, r), do: r.create

  def may_reopen?(%CompanyTask{creator_id: c}, user, r),
    do: (c == user.id and r.create) or r.edit_others

  # --- read -----------------------------------------------------------------

  def get_task(id, company, user) do
    case Ecto.UUID.cast(id) do
      {:ok, id} ->
        from(t in visible_to(company, user), where: t.id == ^id)
        |> Repo.one()
        |> Repo.preload([:assignee, :creator, :closed_by])

      :error ->
        nil
    end
  end

  def assignable_users(company) do
    from(u in User,
      join: cu in CompanyUser,
      on: cu.user_id == u.id,
      where: cu.company_id == ^company.id and cu.role in ^@closers,
      order_by: u.email,
      select: %{id: u.id, email: u.email}
    )
    |> Repo.all()
  end

  # --- write ----------------------------------------------------------------

  def change_task(%CompanyTask{} = task, attrs \\ %{}) do
    CompanyTask.changeset(task, Notes.normalize_visibility(attrs))
  end

  def create_task(attrs, company, user) do
    attrs = Notes.normalize_visibility(attrs)

    if can?(user, :create_task, company) do
      id = Ecto.UUID.generate()

      changeset =
        %CompanyTask{id: id, series_id: id, company_id: company.id, creator_id: user.id}
        |> CompanyTask.changeset(Map.delete(attrs, "links"))
        |> validate_assignee(company)

      Multi.new()
      |> Multi.insert(:task, changeset)
      |> insert_links(Map.get(attrs, "links") || [], company, user)
      |> Repo.transaction()
      |> case do
        {:ok, %{task: t}} ->
          broadcast(company)
          {:ok, Repo.preload(t, [:assignee, :creator, :closed_by])}

        {:error, :task, cs, _} ->
          {:error, cs}

        {:error, _step, reason, _} ->
          {:error, reason}
      end
    else
      :not_authorise
    end
  end

  @doc "`task` must be the struct the editor loaded — its lock_version detects a concurrent save."
  def update_task(%CompanyTask{} = task, attrs, company, user) do
    attrs = attrs |> Notes.normalize_visibility() |> Map.delete("links")

    with %CompanyTask{} = current <- get_task(task.id, company, user) || {:error, :not_found},
         true <- may_edit?(current, user, rights(company, user)) || :not_authorise,
         true <- current.status == "open" || {:error, :closed} do
      changeset = task |> CompanyTask.changeset(attrs) |> validate_assignee(company)

      cond do
        changeset.changes == %{} ->
          {:ok, current}

        not changeset.valid? ->
          {:error, changeset}

        true ->
          # One transaction: a task narrowed without its notes would leak them.
          # The UPDATE's row lock also serialises with a note being written
          # about this task (Notes reads the task FOR SHARE in its own
          # transaction), so no note keeps the old, wider visibility.
          Multi.new()
          |> Multi.update(:task, Ecto.Changeset.optimistic_lock(changeset, :lock_version))
          |> Multi.run(:notes, fn repo, %{task: t} ->
            if Map.has_key?(changeset.changes, :visibility),
              do: {:ok, sync_task_note_visibility(repo, t, company)},
              else: {:ok, 0}
          end)
          |> Repo.transaction()
          |> case do
            {:ok, %{task: t}} ->
              broadcast(company)
              {:ok, Repo.preload(t, [:assignee, :creator, :closed_by], force: true)}

            {:error, :task, cs, _} ->
              {:error, cs}

            {:error, _step, reason, _} ->
              {:error, reason}
          end
      end
    end
  rescue
    Ecto.StaleEntryError -> {:error, :stale}
  end

  defp sync_task_note_visibility(repo, task, company) do
    {n, _} =
      from(n in FullCircle.Notes.Note,
        where:
          n.company_id == ^company.id and n.subject_type == "Task" and
            n.subject_id == ^task.id and is_nil(n.deleted_at)
      )
      |> repo.update_all(set: [visibility: task.visibility])

    n
  end

  def delete_task(%CompanyTask{} = task, company, user) do
    with %CompanyTask{} = current <- get_task(task.id, company, user) || {:error, :not_found},
         true <- may_edit?(current, user, rights(company, user)) || :not_authorise,
         true <- current.status == "open" || {:error, :closed} do
      current
      |> Ecto.Changeset.change(deleted_at: DateTime.utc_now(:second), deleted_by_id: user.id)
      |> Repo.update()
      |> tap(fn
        {:ok, _} -> broadcast(company)
        _ -> :ok
      end)
    end
  end

  defp validate_assignee(cs, company) do
    case Ecto.Changeset.get_change(cs, :assignee_id) do
      nil ->
        cs

      id ->
        ok? =
          Repo.exists?(
            from(cu in CompanyUser,
              where: cu.company_id == ^company.id and cu.user_id == ^id and cu.role in ^@closers
            )
          )

        if ok?,
          do: cs,
          else: Ecto.Changeset.add_error(cs, :assignee_id, "cannot be assigned tasks")
    end
  end

  @doc """
  Linkable resolve for "Task": visible tasks are `{:ok, target}`; tasks that
  exist in the company but are hidden from this user are `{:error, :restricted}`
  (so a link shows "Restricted record", not "(deleted Task)").
  """
  def resolve_tasks(ids, company, user) do
    found =
      from(t in visible_to(company, user), where: t.id in ^ids)
      |> Repo.all()
      |> Map.new(fn t -> {t.id, {:ok, target(t, company)}} end)

    hidden =
      from(t in CompanyTask,
        join: c in subquery(Sys.user_company(company, user)),
        on: c.id == t.company_id,
        where: t.id in ^ids and is_nil(t.deleted_at),
        select: t.id
      )
      |> Repo.all()
      |> Enum.reject(&Map.has_key?(found, &1))

    Map.merge(found, Map.new(hidden, &{&1, {:error, :restricted}}))
  end

  def search_titles(terms, company, user) do
    pattern = "%#{FullCircle.CommandPalette.Types.escape_like(terms)}%"

    from(t in visible_to(company, user),
      where: ilike(t.title, ^pattern),
      order_by: [desc: fragment("? = 'open'", t.status), asc_nulls_last: t.due_date],
      limit: 20
    )
    |> Repo.all()
    |> Enum.map(&target(&1, company))
  end

  defp target(t, company) do
    %{
      type: "Task",
      id: t.id,
      title: t.title,
      subtitle: t.due_date && Date.to_string(t.due_date),
      url: Linkable.url("Task", t.id, company)
    }
  end

  # --- repeat, close, reopen ------------------------------------------------

  @doc """
  The next cycle's due date, stepped from the old due date (fixed calendar).
  Months clamp to month end, and a month-end date stays month-end, so a task
  due 31 Jan goes 28 Feb → 31 Mar → 30 Apr instead of sticking at the 28th.
  """
  def next_due_date(%Date{} = d, "day", n), do: Date.add(d, n)
  def next_due_date(%Date{} = d, "week", n), do: Date.add(d, 7 * n)

  def next_due_date(%Date{} = d, "month", n) do
    shifted = Date.shift(d, month: n)
    if d.day == Date.days_in_month(d), do: Date.end_of_month(shifted), else: shifted
  end

  def next_due_date(%Date{} = d, "year", n), do: Date.shift(d, year: n)

  def close_task(%CompanyTask{} = task, kind, closing_note, company, user)
      when kind in [:done, :skipped] do
    with %CompanyTask{} = current <- get_task(task.id, company, user) || {:error, :not_found},
         true <- may_close?(current, user, rights(company, user)) || :not_authorise do
      Multi.new()
      |> Multi.run(:lock, fn repo, _ ->
        status =
          repo.one(
            from(t in CompanyTask,
              where: t.id == ^current.id,
              lock: "FOR UPDATE",
              select: t.status
            )
          )

        if status == "open", do: {:ok, status}, else: {:error, :already_closed}
      end)
      |> Multi.run(:note, fn _repo, _ -> closing_note(closing_note, current, company, user) end)
      |> Multi.update(:closed, CompanyTask.close_changeset(current, kind, user))
      |> Multi.run(:next, fn repo, %{closed: closed} -> spawn_next(repo, closed, user) end)
      |> Repo.transaction()
      |> case do
        {:ok, %{closed: closed, next: next}} ->
          broadcast(company)
          {:ok, %{closed: closed, next: next}}

        {:error, _step, reason, _} ->
          {:error, reason}
      end
    end
  end

  defp closing_note(body, task, company, user) do
    if is_binary(body) and String.trim(body) != "" do
      Notes.create_note(
        %{
          "body" => String.trim(body),
          "subject_type" => "Task",
          "subject_id" => task.id
        },
        company,
        user
      )
    else
      {:ok, nil}
    end
  end

  defp spawn_next(_repo, %CompanyTask{recur_unit: nil}, _user), do: {:ok, nil}

  # A series never gets a second open cycle: when any later cycle exists
  # (a reopened old cycle being closed again), reuse the earliest later open
  # one, or spawn nothing if every later cycle is closed. Only the latest
  # cycle's close inserts a new one.
  defp spawn_next(repo, %CompanyTask{} = t, user) do
    case later_cycle(repo, t, open_first: true) do
      nil -> insert_next(repo, t, user)
      %CompanyTask{status: "open"} = existing -> {:ok, existing}
      %CompanyTask{} -> {:ok, nil}
    end
  end

  # The series' cycles due after `t`, earliest first (open ones first when
  # asked), deterministic on ties.
  defp later_cycle(repo, %CompanyTask{} = t, opts) do
    q =
      from(e in CompanyTask,
        where:
          e.company_id == ^t.company_id and e.series_id == ^t.series_id and e.id != ^t.id and
            is_nil(e.deleted_at) and e.due_date > ^t.due_date,
        limit: 1
      )

    q =
      if opts[:open_first],
        do: from(e in q, order_by: [desc: fragment("? = 'open'", e.status)]),
        else: q

    q = from(e in q, order_by: [asc: e.due_date, asc: e.inserted_at, asc: e.id])
    q = if opts[:lock], do: from(e in q, lock: "FOR UPDATE"), else: q
    repo.one(q)
  end

  defp insert_next(repo, t, user) do
    next = %CompanyTask{
      company_id: t.company_id,
      series_id: t.series_id,
      title: t.title,
      descriptions: t.descriptions,
      due_date: next_due_date(t.due_date, t.recur_unit, t.recur_every),
      recur_unit: t.recur_unit,
      recur_every: t.recur_every,
      reminder_before_days: t.reminder_before_days,
      documents_needed: t.documents_needed,
      assignee_id: t.assignee_id,
      visibility: t.visibility,
      creator_id: t.creator_id
    }

    with {:ok, n} <- repo.insert(next) do
      now = n.inserted_at

      rows =
        from(l in RecordLink,
          where: l.company_id == ^t.company_id and l.from_type == "Task" and l.from_id == ^t.id,
          select: %{to_type: l.to_type, to_id: l.to_id}
        )
        |> repo.all()
        |> Enum.map(fn l ->
          Map.merge(l, %{
            id: Ecto.UUID.generate(),
            company_id: t.company_id,
            from_type: "Task",
            from_id: n.id,
            created_by_id: user.id,
            inserted_at: now
          })
        end)

      repo.insert_all(RecordLink, rows)
      {:ok, n}
    end
  end

  def reopen_task(%CompanyTask{} = task, company, user) do
    with %CompanyTask{} = current <- get_task(task.id, company, user) || {:error, :not_found},
         true <- may_reopen?(current, user, rights(company, user)) || :not_authorise do
      Multi.new()
      |> Multi.run(:lock, fn repo, _ ->
        row =
          repo.one(
            from(t in CompanyTask,
              where: t.id == ^current.id and is_nil(t.deleted_at),
              lock: "FOR UPDATE"
            )
          )

        cond do
          is_nil(row) -> {:error, :not_found}
          row.status == "open" -> {:error, :open}
          true -> {:ok, row}
        end
      end)
      |> Multi.run(:next, fn repo, %{lock: locked} ->
        case spawned_next(repo, locked) do
          nil ->
            {:ok, {nil, false}}

          next ->
            if created_by_close?(next, locked) and untouched?(repo, next) do
              repo.delete_all(
                from(l in RecordLink,
                  where:
                    l.company_id == ^company.id and l.from_type == "Task" and
                      l.from_id == ^next.id
                )
              )

              repo.delete_all(from(t in CompanyTask, where: t.id == ^next.id))
              {:ok, {next, false}}
            else
              {:ok, {next, true}}
            end
        end
      end)
      |> Multi.update(
        :reopened,
        fn %{lock: locked} ->
          Ecto.Changeset.change(locked, status: "open", closed_at: nil, closed_by_id: nil)
        end
      )
      |> Repo.transaction()
      |> case do
        {:ok, %{reopened: r, next: {_, kept}}} ->
          broadcast(company)

          {:ok,
           %{
             reopened: Repo.preload(r, [:assignee, :creator, :closed_by], force: true),
             next_kept: kept
           }}

        {:error, _step, reason, _} ->
          {:error, reason}
      end
    end
  end

  # The cycle that follows this one in the series: the earliest later cycle,
  # whatever its status — the one this close inserted, or the one it reused,
  # or a closed later cycle (then it stays: `next_kept`). Locked so a
  # concurrent edit waits.
  defp spawned_next(_repo, %CompanyTask{recur_unit: nil}), do: nil
  defp spawned_next(repo, %CompanyTask{} = current), do: later_cycle(repo, current, lock: true)

  # Only a cycle created at/after this close can be one it inserted; a reused
  # older cycle is never deleted by the reopen.
  defp created_by_close?(%CompanyTask{inserted_at: at}, %CompanyTask{closed_at: closed_at}),
    do: DateTime.compare(at, closed_at) != :lt

  # add_link does not bump lock_version, so a link added after the cycle was
  # spawned (inserted_at strictly later) also counts as a touch.
  defp untouched?(repo, %CompanyTask{} = t) do
    t.status == "open" and t.lock_version == 0 and
      not repo.exists?(
        from(n in FullCircle.Notes.Note,
          where: n.subject_type == "Task" and n.subject_id == ^t.id and is_nil(n.deleted_at)
        )
      ) and
      not repo.exists?(
        from(l in RecordLink,
          where:
            l.company_id == ^t.company_id and l.from_type == "Task" and l.from_id == ^t.id and
              l.inserted_at > ^t.inserted_at
        )
      )
  end

  def series_cycles(%CompanyTask{} = task, company, user) do
    from(t in visible_to(company, user),
      where: t.series_id == ^task.series_id and t.id != ^task.id,
      order_by: [desc_nulls_last: t.due_date, desc: t.inserted_at]
    )
    |> Repo.all()
    |> Repo.preload(:closed_by)
  end

  # --- lists and badge ------------------------------------------------------

  def today(company), do: company.timezone |> DateTime.now!() |> DateTime.to_date()

  def group_of(%CompanyTask{status: s}, _today) when s != "open", do: :closed
  def group_of(%CompanyTask{due_date: nil}, _today), do: :someday

  def group_of(%CompanyTask{due_date: d, reminder_before_days: r}, today) do
    cond do
      Date.compare(d, today) == :lt -> :overdue
      d == today -> :due_soon
      r && Date.compare(Date.add(d, -r), today) != :gt -> :due_soon
      true -> :upcoming
    end
  end

  def list_tasks(company, user, filters, opts) do
    page = Keyword.fetch!(opts, :page)
    per_page = Keyword.fetch!(opts, :per_page)
    today = Keyword.get(opts, :today) || today(company)
    filters = filters || %{}

    tasks =
      visible_to(company, user)
      |> scope(filters["scope"] || "mine", user)
      |> state(filters["state"] || "open", today)
      |> terms(filters["terms"])
      |> offset(^((page - 1) * per_page))
      |> limit(^per_page)
      |> Repo.all()
      |> Repo.preload([:assignee, :closed_by])

    ids = Enum.map(tasks, & &1.id)
    latest = latest_notes(ids, company, user)
    counts = Notes.count_by_records(company, user, "Task", ids)
    links = link_counts(ids, company)

    Enum.map(tasks, fn t ->
      %{
        id: t.id,
        task: t,
        group: group_of(t, today),
        latest_note: Map.get(latest, t.id),
        note_count: Map.get(counts, t.id, 0),
        link_count: Map.get(links, t.id, 0)
      }
    end)
  end

  def badge_count(company, user, today \\ nil) do
    today = today || today(company)

    from(t in visible_to(company, user),
      where: t.status == "open" and not is_nil(t.due_date),
      where:
        t.due_date <= ^today or
          (not is_nil(t.reminder_before_days) and
             fragment("? - ? <= ?", t.due_date, t.reminder_before_days, ^today)),
      select: count(t.id)
    )
    |> scope("mine", user)
    |> Repo.one()
  end

  defp scope(q, "all", _user), do: q

  defp scope(q, _mine, user) do
    from(t in q,
      where: t.assignee_id == ^user.id or (is_nil(t.assignee_id) and t.creator_id == ^user.id)
    )
  end

  defp state(q, "closed", _today) do
    from(t in q,
      where: t.status != "open",
      order_by: [desc: t.closed_at, asc: t.title, asc: t.id]
    )
  end

  # The SQL twin of group_of/2: 0 overdue, 1 due soon, 2 upcoming, 3 someday.
  defp state(q, _open, today) do
    from(t in q,
      where: t.status == "open",
      order_by: [
        asc:
          fragment(
            "CASE WHEN ? IS NULL THEN 3 WHEN ? < ? THEN 0 WHEN ? = ? OR (? IS NOT NULL AND ? - ? <= ?) THEN 1 ELSE 2 END",
            t.due_date,
            t.due_date,
            ^today,
            t.due_date,
            ^today,
            t.reminder_before_days,
            t.due_date,
            t.reminder_before_days,
            ^today
          ),
        asc_nulls_last: t.due_date,
        asc: t.title,
        asc: t.id
      ]
    )
  end

  defp terms(q, nil), do: q

  defp terms(q, terms) do
    words = String.split(terms, ~r/\s+/, trim: true)

    if words == [] do
      q
    else
      q = from(t in q, left_join: a in assoc(t, :assignee), as: :assignee)

      Enum.reduce(words, q, fn w, q ->
        pattern = "%#{FullCircle.CommandPalette.Types.escape_like(w)}%"

        from([t, assignee: a] in q,
          where:
            ilike(t.title, ^pattern) or ilike(coalesce(t.descriptions, ""), ^pattern) or
              ilike(coalesce(a.email, ""), ^pattern)
        )
      end)
    end
  end

  defp link_counts([], _company), do: %{}

  defp link_counts(ids, company) do
    from(l in RecordLink,
      where: l.company_id == ^company.id and l.from_type == "Task" and l.from_id in ^ids,
      group_by: l.from_id,
      select: {l.from_id, count(l.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  # Newest visible progress note per task, one query for the whole page.
  defp latest_notes([], _company, _user), do: %{}

  defp latest_notes(ids, company, user) do
    from(n in Notes.visible_to(company, user),
      where: n.subject_type == "Task" and n.subject_id in ^ids,
      distinct: n.subject_id,
      order_by: [desc: n.inserted_at, desc: n.id],
      select: {n.subject_id, %{body: n.body, inserted_at: n.inserted_at}}
    )
    |> Repo.all()
    |> Map.new()
  end

  # --- links ----------------------------------------------------------------

  defp insert_links(multi, links, company, user) do
    links
    |> Enum.with_index()
    |> Enum.reduce(multi, fn {link, i}, m ->
      Multi.run(m, {:link, i}, fn repo, %{task: task} ->
        type = link["type"] || link[:type]
        id = link["id"] || link[:id]

        case Linkable.resolve(type, id, company, user) do
          {:ok, _} -> repo.insert(link_changeset(task, type, id, company, user))
          {:error, _} -> {:error, {:link, :not_found}}
        end
      end)
    end)
  end

  defp link_changeset(task, type, id, company, user) do
    RecordLink.changeset(%RecordLink{}, %{
      company_id: company.id,
      from_type: "Task",
      from_id: task.id,
      to_type: type,
      to_id: id,
      created_by_id: user.id
    })
  end

  @doc """
  Visible tasks that link to this record (`record_links` with `from_type`
  "Task"). Open cycles first, then by due date. A task the user cannot see
  is absent.
  """
  def for_record(type, id, company, user) do
    from(t in visible_to(company, user),
      join: l in RecordLink,
      on: l.from_type == "Task" and l.from_id == t.id and l.company_id == ^company.id,
      where: l.to_type == ^type and l.to_id == ^id,
      order_by: [
        asc: fragment("case when ? = 'open' then 0 else 1 end", t.status),
        asc_nulls_last: t.due_date,
        asc: t.title,
        asc: t.id
      ]
    )
    |> Repo.all()
  end

  def list_links(%CompanyTask{} = task, company, user) do
    rows =
      from(l in RecordLink,
        where: l.company_id == ^company.id and l.from_type == "Task" and l.from_id == ^task.id,
        order_by: [asc: l.inserted_at]
      )
      |> Repo.all()

    resolved = Linkable.resolve_many(Enum.map(rows, &{&1.to_type, &1.to_id}), company, user)

    Enum.map(rows, fn l ->
      %{link_id: l.id, type: l.to_type, id: l.to_id, target: resolved[{l.to_type, l.to_id}]}
    end)
  end

  def add_link(%CompanyTask{} = task, type, id, company, user) do
    with %CompanyTask{} = current <- get_task(task.id, company, user) || {:error, :not_found},
         true <- may_edit?(current, user, rights(company, user)) || :not_authorise,
         true <- current.status == "open" || {:error, :closed},
         {:ok, _} <- Linkable.resolve(type, id, company, user) do
      Repo.insert(link_changeset(current, type, id, company, user))
    end
  end

  def remove_link(%CompanyTask{} = task, link_id, company, user) do
    with %CompanyTask{} = current <- get_task(task.id, company, user) || {:error, :not_found},
         true <- may_edit?(current, user, rights(company, user)) || :not_authorise,
         true <- current.status == "open" || {:error, :closed},
         %RecordLink{} = link <-
           Repo.one(
             from(l in RecordLink,
               where:
                 l.id == ^link_id and l.company_id == ^company.id and l.from_type == "Task" and
                   l.from_id == ^current.id
             )
           ) || {:error, :not_found} do
      Repo.delete(link)
    end
  end
end
