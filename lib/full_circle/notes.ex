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

  def can_edit?(%Note{} = note, company, user) do
    can_read?(note, company, user) and
      ((note.author_id == user.id and can?(user, :create_note, company)) or
         can?(user, :edit_others_note, company))
  end

  def can_delete?(%Note{} = note, company, user) do
    can_read?(note, company, user) and
      ((note.author_id == user.id and can?(user, :create_note, company)) or
         can?(user, :delete_others_note, company))
  end

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

  def list_versions(%Note{} = note, company, user) do
    if can_read?(note, company, user) do
      from(v in NoteVersion, where: v.note_id == ^note.id, order_by: [desc: v.version])
      |> Repo.all()
      |> Repo.preload([:edited_by, :written_by])
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
         true <- can_edit?(current, company, user) || :not_authorise do
      changeset = note |> Note.changeset(attrs) |> validate_subject(company, user)

      if changeset.changes == %{} do
        {:ok, current}
      else
        changeset =
          changeset
          |> Ecto.Changeset.put_change(:updated_by_id, user.id)
          |> Ecto.Changeset.optimistic_lock(:lock_version)

        Multi.new()
        |> snapshot(current, user)
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
         true <- can_delete?(current, company, user) || :not_authorise do
      Multi.new()
      |> snapshot(current, user)
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

  defp snapshot(multi, current, user) do
    multi
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

  defp validate_subject(changeset, company, user) do
    type = Ecto.Changeset.get_field(changeset, :subject_type)
    id = Ecto.Changeset.get_field(changeset, :subject_id)

    cond do
      is_nil(type) or is_nil(id) ->
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

  # Replaced by the real search in the search task.
  def search(_company, _user, _terms, _filters, _opts), do: []

  def add_link(%Note{} = note, type, id, company, user) do
    with %Note{} = current <- get_note(note.id, company, user) || {:error, :not_found},
         true <- can_edit?(current, company, user) || :not_authorise,
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
         true <- can_edit?(current, company, user) || :not_authorise,
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
end
