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
          changeset
          |> Ecto.Changeset.optimistic_lock(:lock_version)
          |> Repo.update()
          |> case do
            {:ok, t} ->
              broadcast(company)
              {:ok, Repo.preload(t, [:assignee, :creator, :closed_by], force: true)}

            {:error, cs} ->
              {:error, cs}
          end
      end
    end
  rescue
    Ecto.StaleEntryError -> {:error, :stale}
  end

  def delete_task(%CompanyTask{} = task, company, user) do
    with %CompanyTask{} = current <- get_task(task.id, company, user) || {:error, :not_found},
         true <- may_edit?(current, user, rights(company, user)) || :not_authorise do
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
          "subject_id" => task.id,
          "visibility" => FullCircle.Notes.Note.private_visibility()
        },
        company,
        user
      )
    else
      {:ok, nil}
    end
  end

  defp spawn_next(_repo, %CompanyTask{recur_unit: nil}, _user), do: {:ok, nil}

  defp spawn_next(repo, %CompanyTask{} = t, user) do
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
      now = DateTime.utc_now(:second)

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
         true <- may_reopen?(current, user, rights(company, user)) || :not_authorise,
         true <- current.status != "open" || {:error, :open} do
      next = spawned_next(current)
      remove? = next != nil and untouched?(next)

      Multi.new()
      |> Multi.update(
        :reopened,
        Ecto.Changeset.change(current, status: "open", closed_at: nil, closed_by_id: nil)
      )
      |> Multi.run(:next, fn repo, _ ->
        if remove? do
          repo.delete_all(
            from(l in RecordLink,
              where:
                l.company_id == ^company.id and l.from_type == "Task" and l.from_id == ^next.id
            )
          )

          repo.delete(next)
        else
          {:ok, next}
        end
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{reopened: r}} ->
          broadcast(company)

          {:ok,
           %{
             reopened: Repo.preload(r, [:assignee, :creator, :closed_by], force: true),
             next_kept: next != nil and not remove?
           }}

        {:error, _step, reason, _} ->
          {:error, reason}
      end
    end
  end

  # The cycle this task's close inserted: same series, the stepped due date,
  # created no earlier than the close. Scoped by company through `current`.
  defp spawned_next(%CompanyTask{recur_unit: nil}), do: nil

  defp spawned_next(%CompanyTask{} = current) do
    due = next_due_date(current.due_date, current.recur_unit, current.recur_every)

    from(t in CompanyTask,
      where:
        t.company_id == ^current.company_id and t.series_id == ^current.series_id and
          t.id != ^current.id and t.due_date == ^due and is_nil(t.deleted_at) and
          t.inserted_at >= ^current.closed_at,
      limit: 1
    )
    |> Repo.one()
  end

  # add_link does not bump lock_version, so a link added after the cycle was
  # spawned (inserted_at strictly later) also counts as a touch.
  defp untouched?(%CompanyTask{} = t) do
    t.status == "open" and t.lock_version == 0 and
      not Repo.exists?(
        from(n in FullCircle.Notes.Note,
          where: n.subject_type == "Task" and n.subject_id == ^t.id and is_nil(n.deleted_at)
        )
      ) and
      not Repo.exists?(
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
