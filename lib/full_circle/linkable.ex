defmodule FullCircle.Linkable do
  @moduledoc """
  The registry of record types a note or task can be about or link to.

  References are `(type, id)` pairs with no foreign key; this module is the
  whitelist that keeps them honest. Every resolve is scoped to the company
  through `Sys.user_company/2`, so an id from another company is simply not
  found. Adding a type is one entry here plus its UI hooks (see the notes skill).
  """
  import Ecto.Query, warn: false

  alias FullCircle.{Repo, Sys}
  alias FullCircle.Accounting.{Contact, Transaction}
  alias FullCircle.CommandPalette.Types, as: PaletteTypes

  @search_limit 20

  # kind :record — a table with company_id and a title column.
  @records [
    %{type: "Employee", schema: FullCircle.HR.Employee, title: :name, route: "employees"},
    %{type: "Contact", schema: FullCircle.Accounting.Contact, title: :name, route: "contacts"},
    %{type: "Good", schema: FullCircle.Product.Good, title: :name, route: "goods"},
    %{type: "Account", schema: FullCircle.Accounting.Account, title: :name, route: "accounts"},
    %{
      type: "FixedAsset",
      schema: FullCircle.Accounting.FixedAsset,
      title: :name,
      route: "fixed_assets"
    }
  ]

  # kind :document — posted documents found through `transactions`. Like the
  # records above, any company member may see them: document pages have no view
  # permission, and the palette's update_* actions are about editing, not seeing.
  @documents Enum.map(PaletteTypes.type_specs(), fn {type, _action, _label, route} ->
               %{type: type, route: route}
             end)

  def types do
    Enum.map(@records, & &1.type) ++ ["Note", "Task"] ++ Enum.map(@documents, & &1.type)
  end

  def type?(type), do: type in types()

  def url(type, id, company) do
    case spec(type) do
      {:record, %{route: route}} -> "/companies/#{company.id}/#{route}/#{id}/edit"
      {:document, %{route: route}} -> "/companies/#{company.id}/#{route}/#{id}/edit"
      :note -> "/companies/#{company.id}/notes/#{id}"
      :task -> "/companies/#{company.id}/tasks/#{id}"
      nil -> "#"
    end
  end

  def can_view_type?(type, company, user) do
    case spec(type) do
      {:record, _} -> true
      {:document, _} -> true
      :note -> FullCircle.Authorization.can?(user, :view_notes, company)
      :task -> FullCircle.Authorization.can?(user, :view_tasks, company)
      nil -> false
    end
  end

  def resolve(type, id, company, user) do
    resolve_many([{type, id}], company, user) |> Map.fetch!({type, id})
  end

  def resolve_many(refs, company, user) do
    refs
    |> Enum.uniq()
    |> Enum.group_by(fn {type, _} -> type end, fn {_, id} -> id end)
    |> Enum.flat_map(fn {type, ids} ->
      {valid, invalid} = Enum.split_with(ids, &match?({:ok, _}, Ecto.UUID.cast(&1)))
      found = resolve_type(type, valid, company, user)

      Enum.map(invalid, &{{type, &1}, {:error, :not_found}}) ++
        Enum.map(valid, fn id -> {{type, id}, Map.get(found, id, {:error, :not_found})} end)
    end)
    |> Map.new()
  end

  def search(type, terms, company, user) do
    terms = String.trim(terms || "")

    cond do
      terms == "" -> []
      not can_view_type?(type, company, user) -> []
      true -> do_search(spec(type), type, terms, company, user)
    end
  end

  # --- internals ------------------------------------------------------------

  defp spec("Note"), do: :note
  defp spec("Task"), do: :task

  defp spec(type) do
    case Enum.find(@records, &(&1.type == type)) do
      nil ->
        case Enum.find(@documents, &(&1.type == type)) do
          nil -> nil
          d -> {:document, d}
        end

      r ->
        {:record, r}
    end
  end

  defp resolve_type(type, ids, company, user) do
    cond do
      ids == [] -> %{}
      is_nil(spec(type)) -> %{}
      not can_view_type?(type, company, user) -> Map.new(ids, &{&1, {:error, :restricted}})
      true -> fetch(spec(type), type, ids, company, user)
    end
  end

  defp fetch({:record, %{schema: schema, title: title}}, type, ids, company, user) do
    from(r in schema,
      join: c in subquery(Sys.user_company(company, user)),
      on: c.id == r.company_id,
      where: r.id in ^ids,
      select: {r.id, field(r, ^title)}
    )
    |> Repo.all()
    |> Map.new(fn {id, t} -> {id, {:ok, target(type, id, t, nil, company)}} end)
  end

  defp fetch({:document, _}, type, ids, company, user) do
    doc_query(type, company, user)
    |> where([t], t.doc_id in ^ids)
    |> Repo.all()
    |> Map.new(fn row -> {row.doc_id, {:ok, doc_target(type, row, company)}} end)
  end

  defp fetch(:note, _type, ids, company, user) do
    FullCircle.Notes.resolve_notes(ids, company, user)
  end

  defp fetch(:task, _type, ids, company, user) do
    FullCircle.Tasks.resolve_tasks(ids, company, user)
  end

  defp do_search({:record, %{schema: schema, title: title}}, type, terms, company, user) do
    pattern = "%#{PaletteTypes.escape_like(terms)}%"

    from(r in schema,
      join: c in subquery(Sys.user_company(company, user)),
      on: c.id == r.company_id,
      where: ilike(field(r, ^title), ^pattern),
      order_by: field(r, ^title),
      limit: @search_limit,
      select: {r.id, field(r, ^title)}
    )
    |> Repo.all()
    |> Enum.map(fn {id, t} -> target(type, id, t, nil, company) end)
  end

  defp do_search({:document, _}, type, terms, company, user) do
    pattern = "%#{PaletteTypes.escape_like(terms)}%"

    doc_query(type, company, user)
    |> where([t], ilike(t.doc_no, ^pattern))
    |> order_by([t], desc: max(t.doc_date))
    |> limit(@search_limit)
    |> Repo.all()
    |> Enum.map(&doc_target(type, &1, company))
  end

  defp do_search(:note, _type, terms, company, user) do
    FullCircle.Notes.search(company, user, terms, %{}, page: 1, per_page: @search_limit)
    |> Enum.map(fn n ->
      target("Note", n.id, FullCircle.Notes.Note.display_title(n), nil, company)
    end)
  end

  defp do_search(:task, _type, terms, company, user) do
    FullCircle.Tasks.search_titles(terms, company, user)
  end

  @doc """
  Of `refs` — a query selecting `%{owner_id, type, id}`, the records some
  owner points at — the `owner_id`s whose record name, or document number or
  document contact name, or linked task / note title, matches the ILIKE
  `pattern`.

  A linked task or note counts only when `user` may see it (`Tasks.visible_to`,
  `Notes.visible_to`): its chip shows them no title, and a search must not
  reveal one either. A note's title is its `title`, else its body (what
  `Note.display_title/1` shows). Driven from the refs through indexed ids, so
  the cost follows the refs, not the size of `transactions`.
  """
  def matching_refs(refs, pattern, company, user) do
    docs =
      from(r in subquery(refs),
        join: t in Transaction,
        on: t.doc_id == r.id and t.doc_type == r.type,
        left_join: ct in Contact,
        on: ct.id == t.contact_id,
        where: r.type in ^Enum.map(@documents, & &1.type) and t.company_id == ^company.id,
        where: ilike(t.doc_no, ^pattern) or ilike(ct.name, ^pattern),
        select: r.owner_id
      )

    Enum.reduce(@records, docs, fn %{type: type, schema: schema, title: title}, acc ->
      named =
        from(r in subquery(refs),
          join: x in ^schema,
          on: x.id == r.id,
          where: r.type == ^type and x.company_id == ^company.id,
          where: ilike(field(x, ^title), ^pattern),
          select: r.owner_id
        )

      union(acc, ^named)
    end)
    |> union(^titled_task(refs, pattern, company, user))
    |> union(^titled_note(refs, pattern, company, user))
  end

  defp titled_task(refs, pattern, company, user) do
    from(r in subquery(refs),
      join: t in subquery(FullCircle.Tasks.visible_to(company, user)),
      on: t.id == r.id,
      where: r.type == "Task" and ilike(t.title, ^pattern),
      select: r.owner_id
    )
  end

  defp titled_note(refs, pattern, company, user) do
    from(r in subquery(refs),
      join: n in subquery(FullCircle.Notes.visible_to(company, user)),
      on: n.id == r.id,
      where: r.type == "Note" and ilike(coalesce(n.title, n.body), ^pattern),
      select: r.owner_id
    )
  end

  defp doc_query(type, company, user) do
    from(t in Transaction,
      join: c in subquery(Sys.user_company(company, user)),
      on: c.id == t.company_id,
      left_join: ct in Contact,
      on: ct.id == t.contact_id,
      where: t.doc_type == ^type and not is_nil(t.doc_id),
      group_by: [t.doc_id, t.doc_no],
      select: %{
        doc_id: t.doc_id,
        doc_no: t.doc_no,
        doc_date: max(t.doc_date),
        contact: max(ct.name)
      }
    )
  end

  defp doc_target(type, row, company) do
    subtitle =
      [row.contact, row.doc_date && Date.to_string(row.doc_date)]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" · ")

    target(type, row.doc_id, row.doc_no, subtitle, company)
  end

  defp target(type, id, title, subtitle, company) do
    %{type: type, id: id, title: title, subtitle: subtitle, url: url(type, id, company)}
  end
end
