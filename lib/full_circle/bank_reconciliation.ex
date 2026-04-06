defmodule FullCircle.BankReconciliation do
  import Ecto.Query

  alias FullCircle.Repo
  alias FullCircle.Accounting
  alias FullCircle.Accounting.Transaction
  alias FullCircle.BankReconciliation.BankStatementLine
  alias FullCircle.BankReconciliation.LlmMatcher

  def import_statement(account_id, company_id, parsed_lines, source_format) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    entries =
      parsed_lines
      |> Enum.reject(fn line -> Decimal.eq?(line.amount, 0) end)
      |> Enum.map(fn line ->
        %{
          id: Ecto.UUID.generate(),
          statement_date: line.statement_date,
          description: line.description,
          cheque_no: line.cheque_no,
          amount: line.amount,
          reference: line.reference,
          source_format: source_format,
          account_id: account_id,
          company_id: company_id,
          match_group_id: nil,
          inserted_at: now
        }
      end)

    Repo.insert_all(BankStatementLine, entries)
  end

  def list_statement_lines(account_id, company_id, from_date, to_date) do
    eff_from = effective_from_date(account_id, company_id, from_date)

    # Current period (matched + unmatched) + prior unmatched carried forward
    current =
      from(sl in BankStatementLine,
        where: sl.account_id == ^account_id,
        where: sl.company_id == ^company_id,
        where: sl.statement_date >= ^from_date,
        where: sl.statement_date <= ^to_date
      )

    prior_unmatched =
      from(sl in BankStatementLine,
        where: sl.account_id == ^account_id,
        where: sl.company_id == ^company_id,
        where: sl.statement_date >= ^eff_from,
        where: sl.statement_date < ^from_date,
        where: is_nil(sl.match_group_id)
      )

    from(sl in subquery(union_all(current, ^prior_unmatched)),
      order_by: [asc: sl.statement_date, asc: sl.inserted_at],
      select: %{
        id: sl.id,
        statement_date: sl.statement_date,
        description: sl.description,
        cheque_no: sl.cheque_no,
        amount: sl.amount,
        reference: sl.reference,
        match_group_id: sl.match_group_id
      }
    )
    |> Repo.all()
  end

  def list_book_transactions(account, from_date, to_date, company) do
    eff_from = effective_from_date(account.id, company.id, from_date)

    # Current period (matched + unmatched) + prior unreconciled carried forward
    current =
      from(txn in Transaction,
        where: txn.account_id == ^account.id,
        where: txn.company_id == ^company.id,
        where: txn.doc_date >= ^from_date,
        where: txn.doc_date <= ^to_date
      )

    prior_unreconciled =
      from(txn in Transaction,
        where: txn.account_id == ^account.id,
        where: txn.company_id == ^company.id,
        where: txn.doc_date >= ^eff_from,
        where: txn.doc_date < ^from_date,
        where: txn.reconciled == false
      )

    from(txn in subquery(union_all(current, ^prior_unreconciled)),
      order_by: [asc: txn.doc_date, asc: txn.inserted_at],
      select: %{
        id: txn.id,
        doc_date: txn.doc_date,
        doc_type: txn.doc_type,
        doc_no: txn.doc_no,
        doc_id: type(txn.doc_id, :string),
        particulars: coalesce(txn.contact_particulars, txn.particulars),
        amount: txn.amount,
        reconciled: txn.reconciled,
        match_group_id: txn.match_group_id
      }
    )
    |> Repo.all()
  end

  @doc """
  Find the effective from_date for including prior unreconciled items.
  Uses the earliest reconciled transaction date as the cutoff — anything
  before that is legacy data we don't pull in. If no reconciled transaction
  exists, falls back to the user-supplied from_date.
  """
  def effective_from_date(account_id, company_id, from_date) do
    earliest_reconciled =
      from(txn in Transaction,
        where: txn.account_id == ^account_id,
        where: txn.company_id == ^company_id,
        where: txn.reconciled == true,
        select: min(txn.doc_date)
      )
      |> Repo.one()

    earliest_reconciled || from_date
  end

  @doc """
  Match multiple statement lines with multiple book transactions as a group.
  All selected items share the same match_group_id.
  """
  def confirm_group_match(stmt_ids, txn_ids) when stmt_ids != [] and txn_ids != [] do
    group_id = Ecto.UUID.generate()

    Ecto.Multi.new()
    |> Ecto.Multi.update_all(
      :match_statements,
      from(sl in BankStatementLine, where: sl.id in ^stmt_ids),
      set: [match_group_id: group_id]
    )
    |> Ecto.Multi.update_all(
      :match_transactions,
      from(txn in Transaction, where: txn.id in ^txn_ids),
      set: [match_group_id: group_id, reconciled: true]
    )
    |> Repo.transaction()
  end

  def confirm_group_match(_, _), do: {:error, :empty_selection}

  @doc """
  Dismiss statement lines — mark them as matched without a book transaction.
  Used for prior-period cheques that cleared but have no book counterpart in this period.
  """
  def dismiss_statement_lines(stmt_ids) when stmt_ids != [] do
    group_id = Ecto.UUID.generate()

    from(sl in BankStatementLine, where: sl.id in ^stmt_ids)
    |> Repo.update_all(set: [match_group_id: group_id])
  end

  def dismiss_statement_lines(_), do: {:error, :empty_selection}

  @doc """
  Unmatch old groups first, then create a new match group.
  Used when re-matching already-reconciled items.
  """
  def rematch_group(stmt_ids, txn_ids, old_group_ids) do
    multi =
      old_group_ids
      |> Enum.with_index()
      |> Enum.reduce(Ecto.Multi.new(), fn {gid, idx}, multi ->
        multi
        |> Ecto.Multi.update_all(
          :"clear_old_stmts_#{idx}",
          from(sl in BankStatementLine, where: sl.match_group_id == ^gid),
          set: [match_group_id: nil]
        )
        |> Ecto.Multi.update_all(
          :"clear_old_txns_#{idx}",
          from(txn in Transaction, where: txn.match_group_id == ^gid),
          set: [match_group_id: nil, reconciled: false]
        )
      end)

    group_id = Ecto.UUID.generate()

    multi
    |> Ecto.Multi.update_all(
      :match_statements,
      from(sl in BankStatementLine, where: sl.id in ^stmt_ids),
      set: [match_group_id: group_id]
    )
    |> Ecto.Multi.update_all(
      :match_transactions,
      from(txn in Transaction, where: txn.id in ^txn_ids),
      set: [match_group_id: group_id, reconciled: true]
    )
    |> Repo.transaction()
  end

  @doc """
  Unmatch all items in a match group.
  """
  def unmatch_group(match_group_id) when not is_nil(match_group_id) do
    Ecto.Multi.new()
    |> Ecto.Multi.update_all(
      :clear_statements,
      from(sl in BankStatementLine, where: sl.match_group_id == ^match_group_id),
      set: [match_group_id: nil]
    )
    |> Ecto.Multi.update_all(
      :clear_transactions,
      from(txn in Transaction, where: txn.match_group_id == ^match_group_id),
      set: [match_group_id: nil, reconciled: false]
    )
    |> Repo.transaction()
  end

  def unmatch_group(nil), do: {:ok, :no_group}

  @doc """
  Auto-match: finds 1:1 matches by amount + date proximity.
  Returns list of {[stmt_id], [txn_id], score} tuples.
  For many-to-many, users match manually.
  """
  def auto_match(account_id, company_id, from_date, to_date) do
    {stmts, txns} = unmatched_data(account_id, company_id, from_date, to_date)
    greedy_match(stmts, txns)
  end

  def ai_match(account_id, company_id, from_date, to_date, llm_settings) do
    {stmts, txns} = unmatched_data_full(account_id, company_id, from_date, to_date)
    LlmMatcher.match(stmts, txns, llm_settings)
  end

  defp unmatched_data(account_id, company_id, from_date, to_date) do
    stmts =
      from(sl in BankStatementLine,
        where: sl.account_id == ^account_id,
        where: sl.company_id == ^company_id,
        where: sl.statement_date >= ^from_date,
        where: sl.statement_date <= ^to_date,
        where: is_nil(sl.match_group_id),
        select: %{id: sl.id, date: sl.statement_date, amount: sl.amount, cheque_no: sl.cheque_no}
      )
      |> Repo.all()

    txns =
      from(txn in Transaction,
        where: txn.account_id == ^account_id,
        where: txn.company_id == ^company_id,
        where: txn.doc_date >= ^from_date,
        where: txn.doc_date <= ^to_date,
        where: txn.reconciled == false,
        where: is_nil(txn.match_group_id),
        select: %{id: txn.id, date: txn.doc_date, amount: txn.amount, doc_no: txn.doc_no}
      )
      |> Repo.all()

    {stmts, txns}
  end

  defp unmatched_data_full(account_id, company_id, from_date, to_date) do
    stmts =
      from(sl in BankStatementLine,
        where: sl.account_id == ^account_id,
        where: sl.company_id == ^company_id,
        where: sl.statement_date >= ^from_date,
        where: sl.statement_date <= ^to_date,
        where: is_nil(sl.match_group_id),
        select: %{
          id: sl.id,
          statement_date: sl.statement_date,
          amount: sl.amount,
          cheque_no: sl.cheque_no,
          description: sl.description,
          reference: sl.reference
        }
      )
      |> Repo.all()

    txns =
      from(txn in Transaction,
        where: txn.account_id == ^account_id,
        where: txn.company_id == ^company_id,
        where: txn.doc_date >= ^from_date,
        where: txn.doc_date <= ^to_date,
        where: txn.reconciled == false,
        where: is_nil(txn.match_group_id),
        select: %{
          id: txn.id,
          doc_date: txn.doc_date,
          amount: txn.amount,
          doc_no: txn.doc_no,
          doc_type: txn.doc_type,
          particulars: coalesce(txn.contact_particulars, txn.particulars)
        }
      )
      |> Repo.all()

    {stmts, txns}
  end

  defp greedy_match(stmts, txns) do
    candidates =
      for stmt <- stmts, txn <- txns, Decimal.eq?(stmt.amount, txn.amount) do
        score = match_score(stmt, txn)
        {stmt.id, txn.id, score}
      end

    candidates
    |> Enum.sort_by(fn {_, _, score} -> -score end)
    |> pick_matches(MapSet.new(), MapSet.new(), [])
  end

  defp pick_matches([], _used_stmts, _used_txns, acc), do: Enum.reverse(acc)

  defp pick_matches([{stmt_id, txn_id, score} | rest], used_stmts, used_txns, acc) do
    if MapSet.member?(used_stmts, stmt_id) or MapSet.member?(used_txns, txn_id) do
      pick_matches(rest, used_stmts, used_txns, acc)
    else
      pick_matches(
        rest,
        MapSet.put(used_stmts, stmt_id),
        MapSet.put(used_txns, txn_id),
        [{[stmt_id], [txn_id], score} | acc]
      )
    end
  end

  defp match_score(stmt, txn) do
    date_diff = abs(Date.diff(stmt.date, txn.date))

    date_score =
      cond do
        date_diff == 0 -> 40
        date_diff <= 3 -> 20
        date_diff <= 7 -> 10
        true -> 0
      end

    cheque_score =
      if stmt.cheque_no && txn.doc_no &&
           String.contains?(txn.doc_no, stmt.cheque_no) do
        50
      else
        0
      end

    date_score + cheque_score
  end

  @doc """
  Confirm all auto-match suggestions (each is a 1:1 group).
  """
  def confirm_auto_matches(matches) do
    multi =
      matches
      |> Enum.with_index()
      |> Enum.reduce(Ecto.Multi.new(), fn {{stmt_ids, txn_ids, _score}, idx}, multi ->
        group_id = Ecto.UUID.generate()

        multi
        |> Ecto.Multi.update_all(
          :"match_stmts_#{idx}",
          from(sl in BankStatementLine, where: sl.id in ^stmt_ids),
          set: [match_group_id: group_id]
        )
        |> Ecto.Multi.update_all(
          :"match_txns_#{idx}",
          from(txn in Transaction, where: txn.id in ^txn_ids),
          set: [match_group_id: group_id, reconciled: true]
        )
      end)

    Repo.transaction(multi)
  end

  def delete_statement_lines(account_id, company_id, from_date, to_date) do
    # Get match_group_ids to unreconcile related transactions
    group_ids =
      from(sl in BankStatementLine,
        where: sl.account_id == ^account_id,
        where: sl.company_id == ^company_id,
        where: sl.statement_date >= ^from_date,
        where: sl.statement_date <= ^to_date,
        where: not is_nil(sl.match_group_id),
        select: sl.match_group_id,
        distinct: true
      )
      |> Repo.all()

    Ecto.Multi.new()
    |> Ecto.Multi.update_all(
      :unreconcile_all,
      from(txn in Transaction, where: txn.match_group_id in ^group_ids),
      set: [match_group_id: nil, reconciled: false]
    )
    |> Ecto.Multi.delete_all(
      :delete_lines,
      from(sl in BankStatementLine,
        where: sl.account_id == ^account_id,
        where: sl.company_id == ^company_id,
        where: sl.statement_date >= ^from_date,
        where: sl.statement_date <= ^to_date
      )
    )
    |> Repo.transaction()
  end

  def reconciliation_summary(account_id, company_id, from_date, to_date) do
    stmt_summary =
      from(sl in BankStatementLine,
        where: sl.account_id == ^account_id,
        where: sl.company_id == ^company_id,
        where: sl.statement_date >= ^from_date,
        where: sl.statement_date <= ^to_date,
        select: %{
          total_pos: coalesce(sum(fragment("case when ? > 0 then ? else 0 end", sl.amount, sl.amount)), 0),
          total_neg: coalesce(sum(fragment("case when ? < 0 then ? else 0 end", sl.amount, sl.amount)), 0),
          count: count(sl.id),
          matched_count:
            fragment("count(case when ? is not null then 1 end)", sl.match_group_id)
        }
      )
      |> Repo.one()

    book_summary =
      from(txn in Transaction,
        where: txn.account_id == ^account_id,
        where: txn.company_id == ^company_id,
        where: txn.doc_date >= ^from_date,
        where: txn.doc_date <= ^to_date,
        select: %{
          total_pos: coalesce(sum(fragment("case when ? > 0 then ? else 0 end", txn.amount, txn.amount)), 0),
          total_neg: coalesce(sum(fragment("case when ? < 0 then ? else 0 end", txn.amount, txn.amount)), 0),
          count: count(txn.id),
          reconciled_count:
            fragment("count(case when ? = true then 1 end)", txn.reconciled)
        }
      )
      |> Repo.one()

    diff_pos = Decimal.sub(stmt_summary.total_pos, book_summary.total_pos)
    diff_neg = Decimal.sub(stmt_summary.total_neg, book_summary.total_neg)

    %{
      statement_total_pos: stmt_summary.total_pos,
      statement_total_neg: stmt_summary.total_neg,
      statement_count: stmt_summary.count,
      statement_matched: stmt_summary.matched_count,
      statement_unmatched: stmt_summary.count - stmt_summary.matched_count,
      book_total_pos: book_summary.total_pos,
      book_total_neg: book_summary.total_neg,
      book_count: book_summary.count,
      book_reconciled: book_summary.reconciled_count,
      book_unreconciled: book_summary.count - book_summary.reconciled_count,
      diff_pos: diff_pos,
      diff_neg: diff_neg,
      difference: Decimal.add(diff_pos, diff_neg)
    }
  end

  def book_opening_balance(account_id, company_id, before_date) do
    from(txn in Transaction,
      where: txn.account_id == ^account_id,
      where: txn.company_id == ^company_id,
      where: txn.doc_date < ^before_date,
      select: coalesce(sum(txn.amount), 0)
    )
    |> Repo.one()
  end

  def book_closing_balance(account_id, company_id, up_to_date) do
    from(txn in Transaction,
      where: txn.account_id == ^account_id,
      where: txn.company_id == ^company_id,
      where: txn.doc_date <= ^up_to_date,
      select: coalesce(sum(txn.amount), 0)
    )
    |> Repo.one()
  end

  alias FullCircle.BankReconciliation.BankStatementBalance

  def save_statement_balances(company_id, account_id, from_date, to_date, balances) do
    attrs = %{
      account_id: account_id,
      company_id: company_id,
      from_date: from_date,
      to_date: to_date,
      opening_balance: balances.opening_balance,
      closing_balance: balances.closing_balance
    }

    Repo.insert!(
      BankStatementBalance.changeset(%BankStatementBalance{}, attrs),
      on_conflict: {:replace, [:opening_balance, :closing_balance, :updated_at]},
      conflict_target: [:account_id, :company_id, :from_date, :to_date]
    )
  end

  def load_statement_balances(company_id, account_id, from_date, to_date) do
    case Repo.one(
           from(b in BankStatementBalance,
             where: b.account_id == ^account_id,
             where: b.company_id == ^company_id,
             where: b.from_date == ^from_date,
             where: b.to_date == ^to_date
           )
         ) do
      %BankStatementBalance{} = bal ->
        %{opening_balance: bal.opening_balance, closing_balance: bal.closing_balance}

      nil ->
        %{opening_balance: nil, closing_balance: nil}
    end
  end

  @doc """
  Build data for the bank reconciliation print report.
  Returns unmatched statement lines and unmatched book transactions,
  split into positive/negative groups.
  """
  def reconciliation_report_data(account_id, company_id, from_date, to_date) do
    # Use effective_from_date to exclude legacy data before first reconciled transaction
    eff_from = effective_from_date(account_id, company_id, from_date)

    unmatched_stmts =
      from(sl in BankStatementLine,
        where: sl.account_id == ^account_id,
        where: sl.company_id == ^company_id,
        where: sl.statement_date >= ^eff_from,
        where: sl.statement_date <= ^to_date,
        where: is_nil(sl.match_group_id),
        order_by: [asc: sl.statement_date],
        select: %{
          statement_date: sl.statement_date,
          description: sl.description,
          cheque_no: sl.cheque_no,
          amount: sl.amount
        }
      )
      |> Repo.all()

    unmatched_txns =
      from(txn in Transaction,
        where: txn.account_id == ^account_id,
        where: txn.company_id == ^company_id,
        where: txn.doc_date >= ^eff_from,
        where: txn.doc_date <= ^to_date,
        where: txn.reconciled == false,
        order_by: [asc: txn.doc_date],
        select: %{
          doc_date: txn.doc_date,
          doc_type: txn.doc_type,
          doc_no: txn.doc_no,
          particulars: coalesce(txn.contact_particulars, txn.particulars),
          amount: txn.amount
        }
      )
      |> Repo.all()

    %{
      unmatched_stmt_deposits: Enum.filter(unmatched_stmts, &Decimal.gt?(&1.amount, 0)),
      unmatched_stmt_payments: Enum.filter(unmatched_stmts, &Decimal.lt?(&1.amount, 0)),
      unmatched_book_deposits: Enum.filter(unmatched_txns, &Decimal.gt?(&1.amount, 0)),
      unmatched_book_payments: Enum.filter(unmatched_txns, &Decimal.lt?(&1.amount, 0))
    }
  end

  @doc """
  Finalize a reconciliation period: generate report snapshot and save it.
  The snapshot captures the current state so the printed report is frozen.
  """
  def finalize_period(account_id, company_id, from_date, to_date) do
    report = reconciliation_report_data(account_id, company_id, from_date, to_date)
    summary = reconciliation_summary(account_id, company_id, from_date, to_date)
    book_closing = book_closing_balance(account_id, company_id, to_date)

    bal = load_statement_balances(company_id, account_id, from_date, to_date)

    snapshot = %{
      "report" => %{
        "unmatched_stmt_deposits" => serialize_items(report.unmatched_stmt_deposits),
        "unmatched_stmt_payments" => serialize_items(report.unmatched_stmt_payments),
        "unmatched_book_deposits" => serialize_items(report.unmatched_book_deposits),
        "unmatched_book_payments" => serialize_items(report.unmatched_book_payments)
      },
      "summary" => %{
        "statement_count" => summary.statement_count,
        "book_count" => summary.book_count,
        "statement_matched" => summary.statement_matched,
        "statement_unmatched" => summary.statement_unmatched,
        "book_reconciled" => summary.book_reconciled,
        "book_unreconciled" => summary.book_unreconciled
      },
      "stmt_closing" => decimal_to_string(bal.closing_balance),
      "book_closing" => decimal_to_string(book_closing)
    }

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    from(b in BankStatementBalance,
      where: b.account_id == ^account_id,
      where: b.company_id == ^company_id,
      where: b.from_date == ^from_date,
      where: b.to_date == ^to_date
    )
    |> Repo.update_all(set: [report_snapshot: snapshot, finalized_at: now])
  end

  def is_finalized?(account_id, company_id, from_date, to_date) do
    Repo.one(
      from(b in BankStatementBalance,
        where: b.account_id == ^account_id,
        where: b.company_id == ^company_id,
        where: b.from_date == ^from_date,
        where: b.to_date == ^to_date,
        where: not is_nil(b.finalized_at),
        select: true
      )
    ) || false
  end

  def load_snapshot(account_id, company_id, from_date, to_date) do
    Repo.one(
      from(b in BankStatementBalance,
        where: b.account_id == ^account_id,
        where: b.company_id == ^company_id,
        where: b.from_date == ^from_date,
        where: b.to_date == ^to_date,
        where: not is_nil(b.report_snapshot),
        select: %{
          report_snapshot: b.report_snapshot,
          finalized_at: b.finalized_at,
          closing_balance: b.closing_balance
        }
      )
    )
  end

  defp serialize_items(items) do
    Enum.map(items, fn item ->
      Map.new(item, fn
        {k, %Decimal{} = v} -> {to_string(k), Decimal.to_string(v)}
        {k, %Date{} = v} -> {to_string(k), Date.to_iso8601(v)}
        {k, v} -> {to_string(k), v}
      end)
    end)
  end

  defp decimal_to_string(nil), do: nil
  defp decimal_to_string(%Decimal{} = d), do: Decimal.to_string(d)
  defp decimal_to_string(other), do: to_string(other)

  def find_journal_transaction(journal_id, account_id) do
    from(t in Transaction,
      where: t.doc_id == ^journal_id,
      where: t.account_id == ^account_id,
      where: t.doc_type == "Journal",
      limit: 1
    )
    |> Repo.one()
  end

  def get_account_by_name(name, com, user) do
    Accounting.get_account_by_name(name, com, user)
  end
end
