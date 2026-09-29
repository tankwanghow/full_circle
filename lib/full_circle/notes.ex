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
  alias FullCircle.Notes.{Note, NoteVersion}

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
        from(n in base,
          where: is_nil(n.visibility) or ^role in n.visibility or n.author_id == ^user.id
        )
      end
    else
      from(n in query, where: false)
    end
  end

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
  must not show clerks what it said while restricted. Admin and the note's
  author see every version.
  """
  def list_versions(%Note{} = note, company, user) do
    if can_read?(note, company, user) do
      role = user_role_in_company(user.id, company.id)
      query = from(v in NoteVersion, where: v.note_id == ^note.id, order_by: [desc: v.version])

      query =
        if role == "admin" or note.author_id == user.id,
          do: query,
          else: from(v in query, where: is_nil(v.visibility) or ^role in v.visibility)

      query |> Repo.all() |> Repo.preload([:edited_by, :written_by])
    else
      []
    end
  end

  # --- write ----------------------------------------------------------------

  def change_note(%Note{} = note, attrs \\ %{}) do
    Note.changeset(note, normalize(attrs))
  end

  def create_note(attrs, company, user) do
    attrs = normalize(attrs)

    if can?(user, :create_note, company) do
      changeset =
        %Note{company_id: company.id, author_id: user.id, updated_by_id: user.id}
        |> Note.changeset(Map.delete(attrs, "links"))
        |> validate_subject(company, user)

      Multi.new()
      |> Multi.insert(:note, changeset)
      |> insert_links(Map.get(attrs, "links") || [], company, user)
      |> Repo.transaction()
      |> case do
        {:ok, %{note: note}} -> {:ok, Repo.preload(note, [:author, :updated_by, :attachments])}
        {:error, :note, cs, _} -> {:error, cs}
        {:error, _step, reason, _} -> {:error, reason}
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
    attrs = attrs |> normalize() |> Map.delete("links")

    with %Note{} = current <- get_note(note.id, company, user) || {:error, :not_found},
         true <- may_edit?(current, user, rights(company, user)) || :not_authorise do
      changeset = note |> Note.changeset(attrs) |> validate_subject(company, user)

      if changeset.changes == %{} do
        {:ok, current}
      else
        changeset =
          changeset
          |> Ecto.Changeset.put_change(:updated_by_id, user.id)
          |> Ecto.Changeset.optimistic_lock(:lock_version)

        Multi.new()
        |> snapshot(current, user, note.lock_version)
        |> Multi.update(:note, changeset)
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

  # Form checkboxes send a hidden "" so an all-unticked group still submits;
  # "no roles ticked" means public, which is nil.
  defp normalize(attrs) do
    attrs = FullCircle.Helpers.key_to_string(attrs)

    case Map.fetch(attrs, "visibility") do
      {:ok, list} when is_list(list) ->
        roles = list |> Enum.reject(&(&1 in ["", nil])) |> Enum.uniq()
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

  def list_backlinks(%Note{} = note, company, user) do
    from(n in visible_to(company, user),
      join: l in RecordLink,
      on: l.from_type == "Note" and l.from_id == n.id,
      where: l.company_id == ^company.id and l.to_type == "Note" and l.to_id == ^note.id,
      order_by: [desc: n.inserted_at]
    )
    |> Repo.all()
  end

  def notes_for_record(type, id, company, user) do
    about =
      from(n in visible_to(company, user),
        where: n.subject_type == ^type and n.subject_id == ^id
      )
      |> Repo.all()

    about_ids = MapSet.new(about, & &1.id)

    linked =
      from(n in visible_to(company, user),
        join: l in RecordLink,
        on: l.from_type == "Note" and l.from_id == n.id,
        where: l.company_id == ^company.id and l.to_type == ^type and l.to_id == ^id
      )
      |> Repo.all()
      |> Enum.reject(&MapSet.member?(about_ids, &1.id))

    (Enum.map(about, &%{note: &1, relation: :about}) ++
       Enum.map(linked, &%{note: &1, relation: :linked}))
    |> Enum.sort_by(& &1.note.inserted_at, {:desc, DateTime})
    |> then(fn rows ->
      notes = Repo.preload(Enum.map(rows, & &1.note), [:author, :attachments])
      Enum.zip_with(rows, notes, fn row, n -> %{row | note: n} end)
    end)
  end

  @doc """
  Visible notes per record for an index page: notes about the record plus
  notes linking to it, each note counted once. Two queries per call, whatever
  the number of ids.
  """
  def count_by_records(_company, _user, _type, []), do: %{}

  def count_by_records(company, user, type, ids) do
    pairs =
      from(n in visible_to(company, user),
        where: n.subject_type == ^type and n.subject_id in ^ids,
        select: {n.subject_id, n.id}
      )
      |> Repo.all()

    linked =
      from(n in visible_to(company, user),
        join: l in RecordLink,
        on: l.from_type == "Note" and l.from_id == n.id,
        where: l.company_id == ^company.id and l.to_type == ^type and l.to_id in ^ids,
        select: {l.to_id, n.id}
      )
      |> Repo.all()

    (pairs ++ linked)
    |> Enum.uniq()
    |> Enum.frequencies_by(fn {record_id, _} -> record_id end)
  end

  def search(company, user, terms, filters, page: page, per_page: per_page) do
    words = terms |> to_string() |> String.split(~r/\s+/, trim: true)

    visible_to(company, user)
    |> apply_words(words)
    |> apply_filters(filters || %{}, company, user)
    |> order_search(words, terms)
    |> offset(^((page - 1) * per_page))
    |> limit(^per_page)
    |> Repo.all()
    |> Repo.preload(:author)
  end

  # ILIKE decides what matches; word_similarity only orders. CJK text scores
  # near zero on trigrams, so similarity must never be the filter.
  defp apply_words(query, words) do
    Enum.reduce(words, query, fn w, q ->
      pattern = "%#{PaletteTypes.escape_like(w)}%"
      from(n in q, where: ilike(n.body, ^pattern) or ilike(coalesce(n.title, ""), ^pattern))
    end)
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
