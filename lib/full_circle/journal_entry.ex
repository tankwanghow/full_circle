defmodule FullCircle.JournalEntry do
  import Ecto.Query, warn: false
  alias FullCircle.Repo
  import FullCircle.Helpers
  import FullCircle.Authorization

  alias FullCircle.Accounting.{Journal}

  alias FullCircle.Accounting.{
    Contact,
    Transaction
  }

  alias FullCircle.{Sys}
  alias FullCircle.Accounting.Account
  alias FullCircle.StdInterface
  alias Ecto.Multi

  def get_journal_by_no!(no, com, user) do
    id =
      Repo.one(
        from jl in Journal,
          join: com in subquery(Sys.user_company(com, user)),
          on: com.id == jl.company_id,
          where: jl.journal_no == ^no,
          select: jl.id
      )

    get_journal!(id, com, user)
  end

  def get_journal!(id, company, user) do
    Repo.one(
      from jl in Journal,
        join: com in subquery(Sys.user_company(company, user)),
        on: com.id == jl.company_id,
        where: jl.id == ^id,
        preload: [transactions: ^journal_transactions()],
        select: jl
    )
  end

  def get_print_journals!(ids, company, user) do
    Repo.all(
      from obj in Journal,
        join: com in subquery(Sys.user_company(company, user)),
        on: com.id == obj.company_id,
        where: obj.id in ^ids,
        preload: [transactions: ^journal_transactions()],
        select: obj
    )
    |> Enum.map(fn x -> Journal.compute_struct_balance(x) end)
  end

  defp journal_transactions() do
    from txn in Transaction,
      join: ac in Account,
      on: ac.id == txn.account_id,
      left_join: cont in Contact,
      on: cont.id == txn.contact_id,
      select: txn,
      select_merge: %{account_name: ac.name, contact_name: cont.name}
  end

  def journal_index_query(terms, date_from, com, user,
        page: page,
        per_page: per_page
      ) do
    qry =
      from(inv in subquery(journal_raw_query(com, user)))

    qry =
      if terms != "" do
        from inv in subquery(qry),
          order_by: ^similarity_order([:journal_no, :account_info, :particulars], terms)
      else
        qry
      end

    qry =
      if date_from != "" do
        from inv in qry, where: inv.journal_date >= ^date_from, order_by: inv.journal_date
      else
        qry
      end

    qry |> offset((^page - 1) * ^per_page) |> limit(^per_page) |> Repo.all()
  end

  def get_journal_by_id_index_component_field!(id, com, user) do
    from(i in subquery(journal_raw_query(com, user)),
      where: i.id == ^id
    )
    |> Repo.one!()
  end

  defp journal_raw_query(company, user) do
    from txn in Transaction,
      join: com in subquery(Sys.user_company(company, user)),
      on: com.id == txn.company_id and txn.doc_type == "Journal",
      join: ac in Account,
      on: ac.id == txn.account_id,
      left_join: cont in Contact,
      on: cont.id == txn.contact_id,
      order_by: [desc: max(txn.inserted_at)],
      order_by: [txn.doc_no],
      select: %{
        id: txn.doc_id,
        journal_no: txn.doc_no,
        journal_date: txn.doc_date,
        account_info:
          fragment(
            "string_agg((? || ' ' || coalesce(?, '')), ', ')",
            ac.name,
            cont.name
          ),
        particulars: fragment("string_agg(?, ', ')", txn.particulars),
        checked: false,
        old_data: txn.old_data
      },
      group_by: [txn.doc_no, txn.doc_id, txn.doc_date, txn.old_data]
  end

  def create_journal(attrs, com, user) do
    case can?(user, :create_journal, com) do
      true ->
        Multi.new()
        |> create_journal_multi(attrs, com, user)
        |> Repo.transaction()

      false ->
        :not_authorise
    end
  end

  def create_journal_multi(multi, attrs, com, user) do
    gapless_name = String.to_atom("update_gapless_doc" <> gen_temp_id())
    journal_name = :create_journal

    multi
    |> get_gapless_doc_id(gapless_name, "Journal", "JS", com)
    |> Multi.insert(
      journal_name,
      fn mty ->
        doc = Map.get(mty, gapless_name)

        attrs =
          Map.merge(attrs, %{
            "transactions" =>
              Enum.into(attrs["transactions"], %{}, fn {k, v} ->
                {k,
                 Map.merge(v, %{
                   "doc_no" => doc,
                   "doc_type" => "Journal",
                   "doc_date" => attrs["journal_date"],
                   "contact_particulars" => v["particulars"],
                   "company_id" => com.id
                 })}
              end)
          })

        StdInterface.changeset(Journal, %Journal{}, Map.merge(attrs, %{"journal_no" => doc}), com)
      end
    )
    |> Multi.insert("#{journal_name}_log", fn %{^journal_name => entity} ->
      FullCircle.Sys.log_changeset(
        journal_name,
        entity,
        Map.merge(attrs, %{"journal_no" => entity.journal_no}),
        com,
        user
      )
    end)
  end

  def update_journal(%Journal{} = journal, attrs, com, user) do
    case can?(user, :update_journal, com) do
      true ->
        Multi.new()
        |> update_journal_multi(journal, attrs, com, user)
        |> Repo.transaction()

      false ->
        :not_authorise
    end
  rescue
    e in Postgrex.Error ->
      {:sql_error, e.postgres.message}
  end

  def update_journal_multi(multi, journal, attrs, com, user) do
    journal_name = :update_journal

    attrs =
      Map.merge(attrs, %{
        "transactions" =>
          Enum.into(attrs["transactions"], %{}, fn {k, v} ->
            {k,
             Map.merge(v, %{
               "doc_no" => journal.journal_no,
               "doc_type" => "Journal",
               "doc_date" => attrs["journal_date"],
               "contact_particulars" => v["particulars"],
               "company_id" => com.id
             })}
          end)
      })

    multi
    |> Multi.update(journal_name, StdInterface.changeset(Journal, journal, attrs, com))
    |> Sys.insert_log_for(journal_name, attrs, com, user)
  end
end
