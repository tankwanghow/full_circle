defmodule FullCircle.Notes do
  @moduledoc """
  Company memory: notes about any `FullCircle.Linkable` record, or none.

  Every read goes through `visible_to/3`. Edits snapshot the previous state into
  `note_versions`. See `.claude/skills/notes.md`.
  """
  import Ecto.Query, warn: false
  import FullCircle.Authorization

  alias Ecto.Multi
  alias FullCircle.{Linkable, Repo, Sys}
  alias FullCircle.CommandPalette.Types, as: PaletteTypes
  alias FullCircle.Linkable.RecordLink
  alias FullCircle.Notes.{Note, NoteVersion, Trays}

  # --- visibility -----------------------------------------------------------

  def visible_to(query \\ Note, company, user) do
    if can?(user, :view_notes, company) do
      role = user_role_in_company(user.id, company.id)

      base =
        from(n in query,
          join: c in subquery(Sys.user_company(company, user)),
          on: c.id == n.company_id,
          where: is_nil(n.deleted_at)
        )

      if role == "admin" do
        base
      else
        # A note about a task is also readable by whoever can see that task,
        # so "Private" on a task means "the people on this task".
        task_ids = from(t in FullCircle.Tasks.visible_to(company, user), select: t.id)
        # Replies to a note follow its visibility; whoever wrote the note still
        # reads the answers, even when the note is Private or not for their role.
        own_roots = own_root_ids(company, user)

        from(n in base,
          where:
            is_nil(n.visibility) or ^role in n.visibility or n.author_id == ^user.id or
              (n.subject_type == "Task" and n.subject_id in subquery(task_ids)) or
              n.reply_to_id in subquery(own_roots)
        )
      end
    else
      from(n in query, where: false)
    end
  end

  defp own_root_ids(company, user),
    do:
      from(r in Note,
        where: r.company_id == ^company.id and r.author_id == ^user.id,
        select: r.id
      )

  def can_read?(%Note{id: id}, company, user) do
    Repo.exists?(from(n in visible_to(company, user), where: n.id == ^id))
  end

  def can_edit?(%Note{} = note, company, user),
    do: can_read?(note, company, user) and may_edit?(note, user, rights(company, user))

  def can_delete?(%Note{} = note, company, user),
    do: can_read?(note, company, user) and may_delete?(note, user, rights(company, user))

  @doc """
  The user's note permissions in this company, looked up once. Pair with
  `may_edit?/3` / `may_delete?/3` for notes already known to be readable
  (anything returned by `visible_to/3`), so a list costs three lookups in
  total rather than a visibility query per note.
  """
  def rights(company, user) do
    %{
      create: can?(user, :create_note, company),
      edit_others: can?(user, :edit_others_note, company),
      delete_others: can?(user, :delete_others_note, company)
    }
  end

  def may_edit?(%Note{author_id: author_id}, user, rights),
    do: (author_id == user.id and rights.create) or rights.edit_others

  def may_delete?(%Note{author_id: author_id}, user, rights),
    do: (author_id == user.id and rights.create) or rights.delete_others

  # --- read -----------------------------------------------------------------

  def get_note(id, company, user) do
    case Ecto.UUID.cast(id) do
      {:ok, id} ->
        from(n in visible_to(company, user), where: n.id == ^id)
        |> Repo.one()
        |> Repo.preload([:author, :updated_by, :attachments])

      :error ->
        nil
    end
  end

  def resolve_notes(ids, company, user) do
    from(n in visible_to(company, user), where: n.id in ^ids)
    |> Repo.all()
    |> Map.new(fn n ->
      {n.id,
       {:ok,
        %{
          type: "Note",
          id: n.id,
          title: Note.display_title(n),
          subtitle: nil,
          url: Linkable.url("Note", n.id, company)
        }}}
    end)
  end

  @doc """
  Past versions of a note, newest first — each one only if the user could have
  read it *as it was*. A note once restricted to managers and later made public
  must not show clerks what it said while restricted. Admin, the note's author
  and, for a reply, its root's author see every version.
  """
  def list_versions(%Note{} = note, company, user) do
    if can_read?(note, company, user) do
      role = user_role_in_company(user.id, company.id)
      query = from(v in NoteVersion, where: v.note_id == ^note.id, order_by: [desc: v.version])

      query =
        if role == "admin" or note.author_id == user.id or own_root?(note, company, user) do
          query
        else
          # Per version: a version about a task is readable by that task's
          # viewers, judged by the version's own subject, not the note's current one.
          task_ids = from(t in FullCircle.Tasks.visible_to(company, user), select: t.id)

          from(v in query,
            where:
              is_nil(v.visibility) or ^role in v.visibility or
                (v.subject_type == "Task" and v.subject_id in subquery(task_ids))
          )
        end

      query |> Repo.all() |> Repo.preload([:edited_by, :written_by])
    else
      []
    end
  end

  defp own_root?(%Note{reply_to_id: nil}, _company, _user), do: false

  defp own_root?(%Note{reply_to_id: root_id}, company, user),
    do: Repo.exists?(from(r in own_root_ids(company, user), where: r.id == ^root_id))

  # --- write ----------------------------------------------------------------

  def change_note(%Note{} = note, attrs \\ %{}, opts \\ []) do
    Note.changeset(note, normalize_visibility(attrs), opts)
  end

  def create_note(attrs, company, user) do
    attrs = normalize_visibility(attrs)

    if can?(user, :create_note, company) do
      case reply_target(attrs, company, user) do
        {:error, cs} ->
          {:error, cs}

        {:ok, root} ->
          attrs = reply_attrs(attrs, root)

          # A reply's subject is its root's, already checked when the root was
          # saved; it may since be deleted or out of the replier's sight.
          changeset =
            %Note{company_id: company.id, author_id: user.id, updated_by_id: user.id}
            |> Note.changeset(Map.delete(attrs, "links"),
              files?: Trays.has_files?(Map.get(attrs, "tray_id"), company, user)
            )
            |> then(&if(root, do: &1, else: validate_subject(&1, company, user)))

          # Lock order: task row, then the root note, then (on update) the note.
          Multi.new()
          |> Multi.run(:task_visibility, fn repo, _ -> read_task_visibility(repo, changeset) end)
          |> Multi.run(:root, fn repo, _ -> lock_root(repo, root) end)
          |> Multi.insert(:note, fn m ->
            changeset |> follow_root(m.root) |> follow_task_visibility(m.task_visibility)
          end)
          |> insert_links(Map.get(attrs, "links") || [], company, user)
          |> Multi.run(:tray, fn repo, %{note: note} ->
            Trays.claim(repo, Map.get(attrs, "tray_id"), note, company, user)
          end)
          |> Repo.transaction()
          |> case do
            {:ok, %{note: note}} ->
              {:ok, Repo.preload(note, [:author, :updated_by, :attachments])}

            {:error, :note, cs, _} ->
              {:error, cs}

            {:error, :root, :gone, _} ->
              {:error, reply_error()}

            {:error, _step, reason, _} ->
              {:error, reason}
          end
      end
    else
      :not_authorise
    end
  end

  @doc """
  Edits a note. `note` must be the struct the editor loaded — its
  `lock_version` is what detects a concurrent save.
  """
  def update_note(%Note{} = note, attrs, company, user) do
    tray_id = Map.get(attrs, "tray_id")
    attrs = attrs |> normalize_visibility() |> Map.drop(["links", "reply_to_id", "tray_id"])

    with %Note{} = current <- get_note(note.id, company, user) || {:error, :not_found},
         true <- may_edit?(current, user, rights(company, user)) || :not_authorise do
      # A reply's subject and visibility are its root's, never the writer's.
      attrs =
        if current.reply_to_id,
          do: Map.drop(attrs, ["subject_type", "subject_id", "visibility"]),
          else: attrs

      files? = current.attachments != [] or Trays.has_files?(tray_id, company, user)

      changeset =
        note |> Note.changeset(attrs, files?: files?) |> validate_subject(company, user)

      # Unlocked first read so a forged visibility alone is a no-op save; the
      # locked read inside the transaction is the one that is stored.
      {:ok, preview} = read_task_visibility(Repo, changeset, false)
      changeset = follow_task_visibility(changeset, preview)

      cond do
        # validate_required drops the blanked field from `changes`, so an
        # invalid changeset can look like "nothing changed": report it.
        not changeset.valid? ->
          {:error, changeset}

        changeset.changes == %{} ->
          # Only new files (or nothing at all): no version, no lock bump.
          {:ok, _} =
            Repo.transaction(fn -> Trays.claim(Repo, tray_id, current, company, user) end)

          {:ok, Repo.preload(current, [:attachments], force: true)}

        true ->
          changeset =
            changeset
            |> Ecto.Changeset.put_change(:updated_by_id, user.id)
            |> Ecto.Changeset.optimistic_lock(:lock_version)

          # Lock order: task row → root note → reply note — the same order as
          # Tasks.update_task/4 (task UPDATE, then its notes) and a root's save
          # (root, then its replies). Taking the note (snapshot's FOR UPDATE)
          # first would deadlock against a concurrent change of its task or root.
          Multi.new()
          |> Multi.run(:task_visibility, fn repo, _ -> read_task_visibility(repo, changeset) end)
          |> Multi.run(:root, fn repo, _ -> lock_root_or_keep(repo, current.reply_to_id) end)
          |> snapshot(current, user, note.lock_version)
          |> Multi.update(:note, fn m ->
            changeset |> follow_root(m.root) |> follow_task_visibility(m.task_visibility)
          end)
          |> Multi.run(:replies, fn repo, %{note: n} -> sync_replies(repo, current, n) end)
          |> Multi.run(:tray, fn repo, %{note: n} ->
            Trays.claim(repo, tray_id, n, company, user)
          end)
          |> Repo.transaction()
          |> case do
            {:ok, %{note: n}} ->
              {:ok, Repo.preload(n, [:author, :updated_by, :attachments], force: true)}

            {:error, :note, cs, _} ->
              {:error, cs}

            {:error, _, reason, _} ->
              {:error, reason}
          end
      end
    end
  rescue
    Ecto.StaleEntryError -> {:error, :stale}
  end

  def delete_note(%Note{} = note, company, user) do
    with %Note{} = current <- get_note(note.id, company, user) || {:error, :not_found},
         true <- may_delete?(current, user, rights(company, user)) || :not_authorise do
      Multi.new()
      |> snapshot(current, user, nil)
      |> Multi.update(
        :note,
        Ecto.Changeset.change(current,
          deleted_at: DateTime.utc_now(:second),
          deleted_by_id: user.id
        )
      )
      |> Repo.transaction()
      |> case do
        {:ok, %{note: n}} -> {:ok, n}
        {:error, _, reason, _} -> {:error, reason}
      end
    end
  end

  # --- helpers --------------------------------------------------------------

  # Two editors saving at once would both compute the same max(version)+1 and
  # the loser would hit the unique index with a NoteVersion changeset. Locking
  # the note row first serialises them; the loser then sees a moved
  # lock_version and reports :stale before writing anything.
  defp snapshot(multi, current, user, expected_lock) do
    multi
    |> Multi.run(:lock, fn repo, _ ->
      locked =
        repo.one(
          from(n in Note, where: n.id == ^current.id, lock: "FOR UPDATE", select: n.lock_version)
        )

      if is_nil(expected_lock) or locked == expected_lock,
        do: {:ok, locked},
        else: {:error, :stale}
    end)
    |> Multi.run(:version_no, fn repo, _ ->
      max =
        repo.one(from(v in NoteVersion, where: v.note_id == ^current.id, select: max(v.version)))

      {:ok, (max || 0) + 1}
    end)
    |> Multi.insert(:version, fn %{version_no: n} -> NoteVersion.snapshot(current, n, user) end)
  end

  defp insert_links(multi, links, company, user) do
    links
    |> Enum.with_index()
    |> Enum.reduce(multi, fn {link, i}, m ->
      Multi.run(m, {:link, i}, fn repo, %{note: note} ->
        type = link["type"] || link[:type]
        id = link["id"] || link[:id]

        case Linkable.resolve(type, id, company, user) do
          {:ok, _} ->
            %RecordLink{}
            |> RecordLink.changeset(%{
              company_id: company.id,
              from_type: "Note",
              from_id: note.id,
              to_type: type,
              to_id: id,
              created_by_id: user.id
            })
            |> repo.insert()

          {:error, _} ->
            {:error, {:link, :not_found}}
        end
      end)
    end)
  end

  # Only a subject being set or changed is checked. An unchanged subject that
  # has since been deleted (or that this editor cannot resolve) must not block
  # fixing a typo in the body.
  defp validate_subject(changeset, company, user) do
    type = Ecto.Changeset.get_field(changeset, :subject_type)
    id = Ecto.Changeset.get_field(changeset, :subject_id)

    changed? =
      Ecto.Changeset.changed?(changeset, :subject_type) or
        Ecto.Changeset.changed?(changeset, :subject_id)

    cond do
      is_nil(type) or is_nil(id) or not changed? ->
        changeset

      not Linkable.type?(type) ->
        Ecto.Changeset.add_error(changeset, :subject_type, "is invalid")

      match?({:ok, _}, Linkable.resolve(type, id, company, user)) ->
        changeset

      true ->
        Ecto.Changeset.add_error(changeset, :subject_id, "not found")
    end
  end

  # A note about a task is readable by whoever can see that task, so its stored
  # visibility is the task's; the writer does not pick a role. Whether the
  # writer may see the task was already decided by validate_subject (a new or
  # changed subject) or by an earlier save (an unchanged one); this only copies.
  #
  # Run inside the note's transaction, the read takes FOR SHARE on the task
  # row. Tasks.update_task changes the task and syncs its notes in one
  # transaction whose UPDATE holds that row, so the two serialise: a note
  # written while the task narrows either waits and reads the new visibility,
  # or commits first and is caught by the sync. Lock order everywhere: task
  # row, then its notes — so this step runs before any note row lock.
  defp read_task_visibility(repo, changeset, lock? \\ true) do
    with "Task" <- Ecto.Changeset.get_field(changeset, :subject_type),
         id when not is_nil(id) <- Ecto.Changeset.get_field(changeset, :subject_id),
         company_id = Ecto.Changeset.get_field(changeset, :company_id),
         %{visibility: visibility} <- repo.one(task_visibility_query(id, company_id, lock?)) do
      {:ok, {:task, visibility}}
    else
      _ -> {:ok, :not_a_task}
    end
  end

  defp task_visibility_query(id, company_id, lock?) do
    q =
      from(t in FullCircle.Tasks.CompanyTask,
        where: t.id == ^id and t.company_id == ^company_id and is_nil(t.deleted_at),
        select: %{visibility: t.visibility}
      )

    if lock?, do: from(t in q, lock: "FOR SHARE"), else: q
  end

  defp follow_task_visibility(changeset, {:task, visibility}),
    do: Ecto.Changeset.put_change(changeset, :visibility, visibility)

  defp follow_task_visibility(changeset, :not_a_task), do: changeset

  # --- replies --------------------------------------------------------------

  # A reply always attaches to a root its writer can read; replying to a reply
  # joins that reply's root. {:ok, nil} when this is not a reply.
  defp reply_target(attrs, company, user) do
    case attrs["reply_to_id"] do
      blank when blank in [nil, ""] ->
        {:ok, nil}

      id ->
        with %Note{} = target <- get_note(id, company, user),
             %Note{} = root <-
               if(target.reply_to_id,
                 do: get_note(target.reply_to_id, company, user),
                 else: target
               ) do
          {:ok, root}
        else
          _ -> {:error, reply_error()}
        end
    end
  end

  defp reply_error do
    %Note{}
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.add_error(:reply_to_id, "can't be replied to")
    |> Map.put(:action, :insert)
  end

  # The root's subject and visibility; the writer's choices are dropped.
  defp reply_attrs(attrs, nil), do: Map.delete(attrs, "reply_to_id")

  defp reply_attrs(attrs, %Note{} = root) do
    Map.merge(attrs, %{
      "reply_to_id" => root.id,
      "subject_type" => root.subject_type,
      "subject_id" => root.subject_id,
      "visibility" => root.visibility
    })
  end

  defp lock_root(_repo, nil), do: {:ok, nil}

  defp lock_root(repo, %Note{id: id}) do
    case repo.one(root_query(id)) do
      nil -> {:error, :gone}
      root -> {:ok, root}
    end
  end

  # Editing a reply whose root was deleted keeps the reply's stored values.
  defp lock_root_or_keep(_repo, nil), do: {:ok, nil}
  defp lock_root_or_keep(repo, root_id), do: {:ok, repo.one(root_query(root_id))}

  defp root_query(id) do
    from(n in Note,
      where: n.id == ^id and is_nil(n.deleted_at),
      lock: "FOR SHARE",
      select: %{subject_type: n.subject_type, subject_id: n.subject_id, visibility: n.visibility}
    )
  end

  defp follow_root(changeset, nil), do: changeset

  defp follow_root(changeset, root) do
    Ecto.Changeset.change(changeset,
      subject_type: root.subject_type,
      subject_id: root.subject_id,
      visibility: root.visibility
    )
  end

  # A root's new subject or visibility goes to its live replies, in the same
  # transaction (root locked by snapshot, then its replies).
  defp sync_replies(_repo, %Note{reply_to_id: id}, _n) when not is_nil(id), do: {:ok, 0}

  defp sync_replies(repo, current, n) do
    if n.subject_type != current.subject_type or n.subject_id != current.subject_id or
         n.visibility != current.visibility do
      {count, _} =
        repo.update_all(
          from(r in Note, where: r.reply_to_id == ^n.id and is_nil(r.deleted_at)),
          set: [subject_type: n.subject_type, subject_id: n.subject_id, visibility: n.visibility]
        )

      {:ok, count}
    else
      {:ok, 0}
    end
  end

  # Form checkboxes send a hidden "" so an all-unticked group still submits;
  # "no roles ticked" means public, which is nil.
  @doc "Form visibility params → nil (Everyone), [\"admin\"] (Private) or roles. Shared with Tasks."
  def normalize_visibility(attrs) do
    attrs = FullCircle.Helpers.key_to_string(attrs)

    case Map.fetch(attrs, "visibility") do
      {:ok, list} when is_list(list) ->
        roles = list |> Enum.reject(&(&1 in ["", nil])) |> Enum.uniq()
        # "admin" only means something alone (Private); next to real roles it
        # is redundant — admins read everything — so a role replaces Private.
        roles = if roles != ["admin"], do: roles -- ["admin"], else: roles
        Map.put(attrs, "visibility", if(roles == [], do: nil, else: roles))

      {:ok, v} when v in ["", nil] ->
        Map.put(attrs, "visibility", nil)

      _ ->
        attrs
    end
  end

  def list_links(%Note{} = note, company, user) do
    rows =
      from(l in RecordLink,
        where: l.company_id == ^company.id and l.from_type == "Note" and l.from_id == ^note.id,
        order_by: [asc: l.inserted_at]
      )
      |> Repo.all()

    resolved = Linkable.resolve_many(Enum.map(rows, &{&1.to_type, &1.to_id}), company, user)

    Enum.map(rows, fn l ->
      %{link_id: l.id, type: l.to_type, id: l.to_id, target: resolved[{l.to_type, l.to_id}]}
    end)
  end

  def add_link(%Note{} = note, type, id, company, user) do
    with %Note{} = current <- get_note(note.id, company, user) || {:error, :not_found},
         true <- may_edit?(current, user, rights(company, user)) || :not_authorise,
         {:ok, _} <- resolve_link_target(type, id, current, company, user) do
      %RecordLink{}
      |> RecordLink.changeset(%{
        company_id: company.id,
        from_type: "Note",
        from_id: current.id,
        to_type: type,
        to_id: id,
        created_by_id: user.id
      })
      |> Repo.insert()
    end
  end

  # A self-link is refused by a check constraint; let it reach the database so
  # the error lands on the changeset instead of masquerading as "not found".
  defp resolve_link_target("Note", id, %Note{id: id} = note, company, _user),
    do: {:ok, %{type: "Note", id: id, url: Linkable.url("Note", id, company), title: note.body}}

  defp resolve_link_target(type, id, _note, company, user) do
    case Linkable.resolve(type, id, company, user) do
      {:ok, t} -> {:ok, t}
      {:error, _} -> {:error, :not_found}
    end
  end

  def remove_link(%Note{} = note, link_id, company, user) do
    with %Note{} = current <- get_note(note.id, company, user) || {:error, :not_found},
         true <- may_edit?(current, user, rights(company, user)) || :not_authorise,
         %RecordLink{} = link <-
           Repo.one(
             from(l in RecordLink,
               where:
                 l.id == ^link_id and l.company_id == ^company.id and l.from_type == "Note" and
                   l.from_id == ^current.id
             )
           ) || {:error, :not_found} do
      Repo.delete(link)
    end
  end

  @doc """
  Notes that link to `note`, or are about it without being a reply (the
  about… picker still offers notes as subjects). Replies are its thread.
  """
  def list_backlinks(%Note{} = note, company, user) do
    linking =
      from(l in RecordLink,
        where: l.company_id == ^company.id and l.from_type == "Note",
        where: l.to_type == "Note" and l.to_id == ^note.id,
        select: l.from_id
      )

    from(n in visible_to(company, user),
      where:
        (n.subject_type == "Note" and n.subject_id == ^note.id) or
          n.id in subquery(linking),
      order_by: [desc: n.inserted_at]
    )
    |> Repo.all()
  end

  @doc """
  Visible notes about, or linking to, one record, newest first, each once
  (`relation: :about` wins over `:linked`, which wins over `:task_outcome`).
  `limit: n` returns only the newest n; the panel pages with it and asks
  `count_by_records/4` for the total.

  `:task_outcome` is the final note of a **done** task that links the record
  (see `outcomes/3`) — the renewed licence on the payment for it.

  A reply follows its root both ways: it is about what the root is about (the
  column is copied), and it is `:linked` where the root links (read here, not
  copied, so unlinking the root takes its replies with it).
  """
  def notes_for_record(type, id, company, user, opts \\ []) do
    limit = Keyword.get(opts, :limit)

    about =
      from(n in visible_to(company, user),
        where: n.subject_type == ^type and n.subject_id == ^id
      )
      |> newest(limit)
      |> Repo.all()

    # A note that is about the record and also links to it counts as :about;
    # excluding it here (not after the query) keeps each side's limit honest.
    # `in subquery`, not a join: a reply linking here under a root that also
    # does would otherwise come back twice.
    linking =
      from(l in RecordLink,
        where: l.company_id == ^company.id and l.from_type == "Note",
        where: l.to_type == ^type and l.to_id == ^id,
        select: l.from_id
      )

    linked =
      from(n in visible_to(company, user),
        where: n.id in subquery(linking) or n.reply_to_id in subquery(linking),
        where:
          is_nil(n.subject_type) or is_nil(n.subject_id) or
            not (n.subject_type == ^type and n.subject_id == ^id)
      )
      |> newest(limit)
      |> Repo.all()

    # Excluded in SQL like :linked above: a final note already about or
    # linking here shows once, under the stronger relation.
    outcome =
      from(n in visible_to(company, user),
        join: o in subquery(outcomes(company, type, [id])),
        on: o.note_id == n.id,
        where: n.id not in subquery(linking),
        where:
          is_nil(n.subject_type) or is_nil(n.subject_id) or
            not (n.subject_type == ^type and n.subject_id == ^id)
      )
      |> newest(limit)
      |> Repo.all()

    (Enum.map(about, &%{note: &1, relation: :about}) ++
       Enum.map(linked, &%{note: &1, relation: :linked}) ++
       Enum.map(outcome, &%{note: &1, relation: :task_outcome}))
    |> Enum.sort_by(&{DateTime.to_unix(&1.note.inserted_at), &1.note.id}, :desc)
    |> then(&if(limit, do: Enum.take(&1, limit), else: &1))
    |> then(fn rows ->
      notes = Repo.preload(Enum.map(rows, & &1.note), [:author, :attachments])
      Enum.zip_with(rows, notes, fn row, n -> %{row | note: n} end)
    end)
  end

  # `%{record_id, note_id}`: for each **done** task linking one of `ids`, its
  # final note — the latest note about it that is not a reply. Visibility is
  # applied by the caller, to the final note itself: a user who cannot read it
  # sees nothing, never an older note standing in.
  #
  # Only the cycle that owns the link counts: the earliest in its series with
  # that link. Closing a repeating task copies its links onto the next cycle
  # (`Tasks.spawn_next`); without this, next year's outcome would land on this
  # year's payment. Timestamps cannot tell a copy from a link added when the
  # task was created (same second), but copies only ever move forward.
  defp outcomes(company, type, ids) do
    owning =
      from(l in RecordLink,
        as: :link,
        join: t in FullCircle.Tasks.CompanyTask,
        as: :task,
        on: t.id == l.from_id,
        where: l.company_id == ^company.id and l.from_type == "Task",
        where: l.to_type == ^type and l.to_id in ^ids,
        where: t.status == "done" and is_nil(t.deleted_at),
        where:
          not exists(
            from(l2 in RecordLink,
              join: t2 in FullCircle.Tasks.CompanyTask,
              on: t2.id == l2.from_id,
              where: l2.company_id == parent_as(:link).company_id and l2.from_type == "Task",
              where:
                l2.to_type == parent_as(:link).to_type and l2.to_id == parent_as(:link).to_id,
              where: t2.series_id == parent_as(:task).series_id,
              # inserted_at is to the second; on a tie, the next cycle is the
              # one due later (next_due_date always moves forward).
              where:
                t2.inserted_at < parent_as(:task).inserted_at or
                  (t2.inserted_at == parent_as(:task).inserted_at and
                     t2.due_date < parent_as(:task).due_date),
              select: 1
            )
          ),
        select: %{record_id: l.to_id, task_id: t.id}
      )

    finals =
      from(n in Note,
        where: n.company_id == ^company.id and n.subject_type == "Task",
        where: n.subject_id in subquery(from(o in subquery(owning), select: o.task_id)),
        where: is_nil(n.deleted_at) and is_nil(n.reply_to_id),
        distinct: n.subject_id,
        order_by: [asc: n.subject_id, desc: n.inserted_at, desc: n.id],
        select: %{task_id: n.subject_id, note_id: n.id}
      )

    from(o in subquery(owning),
      join: f in subquery(finals),
      on: f.task_id == o.task_id,
      select: %{record_id: o.record_id, note_id: f.note_id}
    )
  end

  defp newest(query, nil), do: query

  defp newest(query, limit),
    do: from(n in query, order_by: [desc: n.inserted_at, desc: n.id], limit: ^limit)

  @doc """
  Visible notes per record for an index page: notes about the record, notes
  linking to it, and done linked tasks' final notes (`notes_for_record/5`),
  each note counted once. Three queries per call, whatever the number of ids.
  """
  def count_by_records(_company, _user, _type, []), do: %{}

  def count_by_records(company, user, type, ids) do
    pairs =
      from(n in visible_to(company, user),
        where: n.subject_type == ^type and n.subject_id in ^ids,
        select: {n.subject_id, n.id}
      )
      |> Repo.all()

    # A reply counts where its root links (see `notes_for_record/5`).
    linked =
      from(n in visible_to(company, user),
        join: l in RecordLink,
        on: l.from_type == "Note" and (l.from_id == n.id or l.from_id == n.reply_to_id),
        where: l.company_id == ^company.id and l.to_type == ^type and l.to_id in ^ids,
        select: {l.to_id, n.id}
      )
      |> Repo.all()

    outcome =
      from(n in visible_to(company, user),
        join: o in subquery(outcomes(company, type, ids)),
        on: o.note_id == n.id,
        select: {o.record_id, n.id}
      )
      |> Repo.all()

    (pairs ++ linked ++ outcome)
    |> Enum.uniq()
    |> Enum.frequencies_by(fn {record_id, _} -> record_id end)
  end

  @doc """
  What the feed shows around each note in `notes` (already visible): its
  subject, its links (each resolved for this user), how many visible live
  replies it has (`replies` — notes that only link here do not count) and, for
  a reply, its root (`reply_to`: `%{id, title, state: :ok | :deleted | :hidden}`).
  A fixed six queries per page, however many notes.
  """
  def feed_details([], _company, _user), do: %{}

  def feed_details(notes, company, user) do
    ids = Enum.map(notes, & &1.id)

    links =
      from(l in RecordLink,
        where: l.company_id == ^company.id and l.from_type == "Note" and l.from_id in ^ids,
        order_by: [asc: l.inserted_at]
      )
      |> Repo.all()

    subjects = for n <- notes, n.subject_type, do: {n.subject_type, n.subject_id}

    resolved =
      Linkable.resolve_many(subjects ++ Enum.map(links, &{&1.to_type, &1.to_id}), company, user)

    replies =
      from(n in visible_to(company, user),
        where: n.reply_to_id in ^ids,
        group_by: n.reply_to_id,
        select: {n.reply_to_id, count(n.id)}
      )
      |> Repo.all()
      |> Map.new()

    root_ids = notes |> Enum.map(& &1.reply_to_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    visible_roots =
      from(n in visible_to(company, user), where: n.id in ^root_ids, select: {n.id, n})
      |> Repo.all()
      |> Map.new()

    deleted_roots =
      from(n in Note,
        where: n.id in ^root_ids and n.company_id == ^company.id and not is_nil(n.deleted_at),
        select: n.id
      )
      |> Repo.all()
      |> MapSet.new()

    links_by_note = Enum.group_by(links, & &1.from_id)

    Map.new(notes, fn n ->
      {n.id,
       %{
         subject: n.subject_type && resolved[{n.subject_type, n.subject_id}],
         links:
           for l <- Map.get(links_by_note, n.id, []) do
             %{type: l.to_type, id: l.to_id, target: resolved[{l.to_type, l.to_id}]}
           end,
         replies: Map.get(replies, n.id, 0),
         reply_to: reply_to_tag(n.reply_to_id, visible_roots, deleted_roots)
       }}
    end)
  end

  defp reply_to_tag(nil, _visible, _deleted), do: nil

  defp reply_to_tag(root_id, visible, deleted) do
    cond do
      root = visible[root_id] -> %{id: root_id, title: Note.display_title(root), state: :ok}
      MapSet.member?(deleted, root_id) -> %{id: root_id, title: nil, state: :deleted}
      true -> %{id: root_id, title: nil, state: :hidden}
    end
  end

  @doc "Visible live replies of a root, oldest first, as feed items."
  def thread(%Note{id: root_id}, company, user) do
    notes =
      from(n in visible_to(company, user),
        where: n.reply_to_id == ^root_id,
        order_by: [asc: n.inserted_at, asc: n.id]
      )
      |> Repo.all()
      |> Repo.preload([:author, :updated_by, :attachments])

    details = feed_details(notes, company, user)
    Enum.map(notes, &%{id: &1.id, note: &1, d: Map.fetch!(details, &1.id)})
  end

  @doc """
  The root of a reply as this user may see it: `:self` for a root,
  `{:root, note}`, or `{:deleted, nil}` / `{:hidden, nil}`.
  """
  def root_of(%Note{reply_to_id: nil}, _company, _user), do: :self

  def root_of(%Note{reply_to_id: root_id}, company, user) do
    case get_note(root_id, company, user) do
      %Note{} = root ->
        {:root, root}

      nil ->
        deleted? =
          Repo.exists?(
            from(n in Note,
              where: n.id == ^root_id and n.company_id == ^company.id and not is_nil(n.deleted_at)
            )
          )

        if deleted?, do: {:deleted, nil}, else: {:hidden, nil}
    end
  end

  def search(company, user, terms, filters, page: page, per_page: per_page) do
    words = terms |> to_string() |> String.split(~r/\s+/, trim: true)

    visible_to(company, user)
    |> apply_words(words, company, user)
    |> apply_filters(filters || %{}, company, user)
    |> order_search(words, terms)
    |> offset(^((page - 1) * per_page))
    |> limit(^per_page)
    |> Repo.all()
    |> Repo.preload(:author)
  end

  # ILIKE decides what matches; word_similarity only orders. CJK text scores
  # near zero on trigrams, so similarity must never be the filter. A word may
  # also match the name, document number or (visible) task/note title of what
  # the note is about or links to (`Linkable.matching_refs/4`) — read now, so
  # a rename or a new link counts at once; nothing is copied onto the note.
  defp apply_words(query, words, company, user) do
    refs = note_refs(company)

    Enum.reduce(words, query, fn w, q ->
      pattern = "%#{PaletteTypes.escape_like(w)}%"

      from(n in q,
        where:
          ilike(n.body, ^pattern) or ilike(coalesce(n.title, ""), ^pattern) or
            n.id in subquery(Linkable.matching_refs(refs, pattern, company, user))
      )
    end)
  end

  # Every record a note points at — its subject and its links — as
  # `%{owner_id, type, id}`.
  defp note_refs(company) do
    links =
      from(l in RecordLink,
        where: l.company_id == ^company.id and l.from_type == "Note",
        select: %{owner_id: l.from_id, type: l.to_type, id: l.to_id}
      )

    from(n in Note,
      where: n.company_id == ^company.id and not is_nil(n.subject_id),
      select: %{owner_id: n.id, type: n.subject_type, id: n.subject_id}
    )
    |> union_all(^links)
  end

  defp apply_filters(query, filters, company, user) do
    Enum.reduce(filters, query, fn
      {"subject_type", t}, q when t not in [nil, ""] -> from(n in q, where: n.subject_type == ^t)
      {"subject_id", id}, q when id not in [nil, ""] -> subject_id_filter(q, id)
      {"mine", "true"}, q -> from(n in q, where: n.author_id == ^user.id)
      {"from", d}, q -> date_filter(q, d, :from, company.timezone)
      {"to", d}, q -> date_filter(q, d, :to, company.timezone)
      _, q -> q
    end)
  end

  # A hand-edited URL can carry anything; a malformed id matches nothing.
  defp subject_id_filter(q, id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> from(n in q, where: n.subject_id == ^id)
      :error -> from(n in q, where: false)
    end
  end

  # The user picks a day on the company's calendar; inserted_at is UTC. A
  # hand-edited URL can carry anything; a bad date drops the filter.
  defp date_filter(q, d, dir, tz) do
    case Date.from_iso8601(to_string(d)) do
      {:ok, date} when dir == :from ->
        from(n in q,
          where:
            fragment("(? AT TIME ZONE 'UTC' AT TIME ZONE ?)::date", n.inserted_at, ^tz) >= ^date
        )

      {:ok, date} ->
        from(n in q,
          where:
            fragment("(? AT TIME ZONE 'UTC' AT TIME ZONE ?)::date", n.inserted_at, ^tz) <= ^date
        )

      _ ->
        q
    end
  end

  defp order_search(query, [], _terms),
    do: from(n in query, order_by: [desc: n.inserted_at, desc: n.id])

  defp order_search(query, _words, terms) do
    from(n in query,
      order_by: [
        desc:
          fragment(
            "word_similarity(?, coalesce(?, '') || ' ' || ?)",
            ^terms,
            n.title,
            n.body
          ),
        desc: n.inserted_at
      ]
    )
  end

  @versioned ~w(title body subject_type subject_id visibility)a

  def version_changes(versions, %Note{} = note) do
    newer_states = [note | versions] |> Enum.take(length(versions))

    Enum.zip_with(versions, newer_states, fn v, newer ->
      changes =
        for f <- @versioned,
            Map.get(v, f) != Map.get(newer, f),
            do: {f, Map.get(v, f), Map.get(newer, f)}

      %{version: v, changes: changes}
    end)
  end
end
