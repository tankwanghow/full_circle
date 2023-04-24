defmodule FullCircle.StdInterface do
  import Ecto.Query, warn: false
  import FullCircle.Authorization
  import FullCircle.Helpers

  alias FullCircle.Repo
  alias Ecto.Multi
  alias FullCircle.Sys

  def get!(klass, id), do: Repo.get!(klass, id)

  def filter(klass, fields, terms, company, user, page: page, per_page: per_page) do
    q =
      from(i in subquery(query(klass, company, user)),
        offset: ^((page - 1) * per_page),
        limit: ^per_page
      )

    q =
      if(terms != "",
        do:
          from(i in q,
            order_by: ^similarity_order(fields, terms),
            order_by: ^fields
          ),
        else: from(i in q)
      )

    Repo.all(q)
  end

  def filter(query, fields, terms, page: page, per_page: per_page) do
    q =
      from(i in subquery(query),
        offset: ^((page - 1) * per_page),
        limit: ^per_page
      )

    q =
      if(terms != "",
        do:
          from(i in q,
            order_by: ^similarity_order(fields, terms),
            order_by: ^fields
          ),
        else: from(i in q)
      )

    Repo.all(q)
  end

  defp query(klass, company, user) do
    from(obj in klass,
      join: com in subquery(Sys.user_companies(company, user)),
      on: com.id == obj.company_id,
      select: obj,
      order_by: [desc: obj.updated_at]
    )
  end

  def create(klass, klass_name, attrs, user, company, multi \\ Multi.new()) do
    action = String.to_atom("create_" <> klass_name)

    case can?(user, action, company) do
      true ->
        multi
        |> Multi.insert(action, changeset(klass, klass.__struct__, attrs, company))
        |> Sys.insert_log_for(action, attrs, company, user)
        |> Repo.transaction()
        |> case do
          {:ok, %{^action => obj}} ->
            {:ok, obj}

          {:error, failed_operation, failed_value, changes_of_far} ->
            {:error, failed_operation, failed_value, changes_of_far}
        end

      false ->
        :not_authorise
    end
  end

  def update(klass, klass_name, obj, attrs, user, company, multi \\ Multi.new()) do
    action = String.to_atom("update_" <> klass_name)

    case can?(user, action, company) do
      true ->
        multi
        |> Multi.update(action, changeset(klass, obj, attrs, company))
        |> Sys.insert_log_for(action, attrs, company, user)
        |> Repo.transaction()
        |> case do
          {:ok, %{^action => nac}} ->
            {:ok, nac}

          {:error, failed_operation, failed_value, changes_of_far} ->
            {:error, failed_operation, failed_value, changes_of_far}
        end

      false ->
        :not_authorise
    end
  end

  def delete(klass, klass_name, obj, user, company, multi \\ Multi.new()) do
    action = String.to_atom("delete_" <> klass_name)
    changeset = changeset(klass, obj, %{}, company)

    case can?(user, action, company) do
      true ->
        try do
          multi
          |> Multi.delete(action, changeset)
          |> Sys.insert_log_for(action, %{"deleted_id_is" => obj.id}, company, user)
          |> FullCircle.Repo.transaction()
          |> case do
            {:ok, %{^action => obj}} ->
              {:ok, obj}

            {:error, failed_operation, failed_value, changes_of_far} ->
              {:error, failed_operation, failed_value, changes_of_far}
          end
        rescue
          e in Postgrex.Error -> {:error, :catched, %{changeset | action: :delete}, e}
        end

      false ->
        :not_authorise
    end
  end

  def changeset(klass, obj, attrs \\ %{}, company, changeset_name \\ :changeset) do
    attrs = Map.merge(attrs, %{company_id: company.id}) |> key_to_string()
    apply(klass, changeset_name, [obj, attrs])
  end
end
