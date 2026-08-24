defmodule FullCircle.BankReconciliation do
  import Ecto.Query

  alias FullCircle.Repo
  alias FullCircle.Accounting
  alias FullCircle.Accounting.Transaction
  alias FullCircle.BankReconciliation.BankStatementLine
  alias FullCircle.BankReconciliation.{AutoMatcher, LlmMatcher}

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
  Correct an unmatched imported statement line (date/amount/description/cheque).
  Matched lines must be unmatched first. Scoped by company.
  """
  def update_statement_line(line_id, company_id, attrs) do
    case Repo.get_by(BankStatementLine, id: line_id, company_id: company_id) do
      nil ->
        {:error, :not_found}

      %BankStatementLine{match_group_id: gid} when not is_nil(gid) ->
        {:error, :matched}

      %BankStatementLine{} = line ->
        line
        |> BankStatementLine.update_changeset(attrs)
        |> Repo.update()
    end
  end

  @doc """
  Delete unmatched selected statement lines. Refuses the whole batch if any
  selected line is already matched.
  """
  def delete_selected_statement_lines(stmt_ids, company_id)
      when is_list(stmt_ids) and stmt_ids != [] do
    matched =
      from(sl in BankStatementLine,
        where: sl.id in ^stmt_ids,
        where: sl.company_id == ^company_id,
        where: not is_nil(sl.match_group_id),
        select: count(sl.id)
      )
      |> Repo.one()

    if matched > 0 do
      {:error, :matched}
    else
      {count, _} =
        from(sl in BankStatementLine,
          where: sl.id in ^stmt_ids,
          where: sl.company_id == ^company_id,
          where: is_nil(sl.match_group_id)
        )
        |> Repo.delete_all()

      {:ok, count}
    end
  end

  def delete_selected_statement_lines(_, _), do: {:error, :empty_selection}

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
    AutoMatcher.match(stmts, txns)
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
        select: %{
          id: sl.id,
          date: sl.statement_date,
          amount: sl.amount,
          cheque_no: sl.cheque_no,
          description: sl.description
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
          date: txn.doc_date,
          amount: txn.amount,
          doc_no: txn.doc_no,
          particulars: coalesce(txn.contact_particulars, txn.particulars)
        }
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
          total_pos:
            coalesce(sum(fragment("case when ? > 0 then ? else 0 end", sl.amount, sl.amount)), 0),
          total_neg:
            coalesce(sum(fragment("case when ? < 0 then ? else 0 end", sl.amount, sl.amount)), 0),
          count: count(sl.id),
          matched_count: fragment("count(case when ? is not null then 1 end)", sl.match_group_id)
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
          total_pos:
            coalesce(
              sum(fragment("case when ? > 0 then ? else 0 end", txn.amount, txn.amount)),
              0
            ),
          total_neg:
            coalesce(
              sum(fragment("case when ? < 0 then ? else 0 end", txn.amount, txn.amount)),
              0
            ),
          count: count(txn.id),
          reconciled_count: fragment("count(case when ? = true then 1 end)", txn.reconciled)
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

  @doc """
  Create a matcher-only Receipt (`:receipt`, positive statement lines) or
  Payment (`:payment`, negative lines) that settles the given outstanding
  invoice transactions, and match it to the originating statement lines —
  all in one database transaction.

  `matchers` are `%{"transaction_id" => id, "account_id" => id,
  "match_amount" => abs amount}` rows (from
  `Accounting.query_transactions_for_matching/5`); their total must equal
  the statement total exactly or `{:error, :allocation_mismatch}` is
  returned. Statement lines must be unmatched, on one account, and all of
  the sign matching the doc kind, else `{:error, :invalid_lines}`.
  """
  def create_settling_doc(kind, stmt_ids, contact_attrs, matchers, company, user)
      when kind in [:receipt, :payment] and is_list(stmt_ids) do
    lines =
      from(sl in BankStatementLine,
        where: sl.id in ^stmt_ids,
        where: sl.company_id == ^company.id,
        where: is_nil(sl.match_group_id)
      )
      |> Repo.all()

    expected_sign = if kind == :receipt, do: :gt, else: :lt
    total = Enum.reduce(lines, Decimal.new(0), &Decimal.add(&1.amount, &2))
    funds = Decimal.abs(total)

    allocated =
      Enum.reduce(matchers, Decimal.new(0), fn m, acc ->
        Decimal.add(acc, Decimal.abs(Decimal.new(m["match_amount"])))
      end)

    cond do
      lines == [] or length(lines) != length(stmt_ids) or
        length(Enum.uniq_by(lines, & &1.account_id)) != 1 or
          not Enum.all?(lines, &(Decimal.compare(&1.amount, 0) == expected_sign)) ->
        {:error, :invalid_lines}

      not Decimal.eq?(allocated, funds) ->
        {:error, :allocation_mismatch}

      not FullCircle.Authorization.can?(user, doc_create_action(kind), company) ->
        :not_authorise

      true ->
        do_create_settling_doc(kind, lines, total, contact_attrs, matchers, company, user)
    end
  end

  defp doc_create_action(:receipt), do: :create_receipt
  defp doc_create_action(:payment), do: :create_payment

  defp do_create_settling_doc(kind, lines, total, contact_attrs, matchers, company, user) do
    account = Repo.get!(FullCircle.Accounting.Account, hd(lines).account_id)
    date = lines |> Enum.map(& &1.statement_date) |> Enum.max(Date)
    stmt_ids = Enum.map(lines, & &1.id)
    doc_type = if kind == :receipt, do: "Receipt", else: "Payment"
    doc_key = if kind == :receipt, do: :create_receipt, else: :create_payment

    matcher_params =
      matchers
      |> Enum.with_index()
      |> Map.new(fn {m, i} ->
        amt = m["match_amount"] |> Decimal.new() |> Decimal.abs()
        # Receipt settles AR (positive balances) → negative match_amount;
        # Payment settles AP (negative balances) → positive match_amount.
        signed = if kind == :receipt, do: Decimal.negate(amt), else: amt

        {"#{i}",
         %{
           "transaction_id" => m["transaction_id"],
           "account_id" => m["account_id"],
           "doc_type" => doc_type,
           "doc_date" => Date.to_iso8601(date),
           "match_amount" => Decimal.to_string(signed),
           "_persistent_id" => "#{i + 1}"
         }}
      end)

    descriptions =
      lines |> Enum.map(& &1.description) |> Enum.uniq() |> Enum.join("; ") |> String.slice(0, 230)

    base = %{
      "contact_id" => contact_attrs["contact_id"],
      "contact_name" => contact_attrs["contact_name"],
      "descriptions" => descriptions,
      "funds_account_name" => account.name,
      "funds_account_id" => account.id,
      "funds_amount" => Decimal.to_string(Decimal.abs(total)),
      "transaction_matchers" => matcher_params
    }

    multi =
      case kind do
        :receipt ->
          Map.merge(base, %{"receipt_no" => "...new...", "receipt_date" => Date.to_iso8601(date)})
          |> then(&FullCircle.ReceiveFund.create_receipt_multi(Ecto.Multi.new(), &1, company, user))

        :payment ->
          Map.merge(base, %{"payment_no" => "...new...", "payment_date" => Date.to_iso8601(date)})
          |> then(&FullCircle.BillPay.create_payment_multi(Ecto.Multi.new(), &1, company, user))
      end

    multi
    |> Ecto.Multi.run(:recon_match, fn _repo, changes ->
      doc = Map.fetch!(changes, doc_key)
      txn = find_doc_transaction(doc.id, account.id, doc_type)

      if txn && Decimal.eq?(txn.amount, total) do
        confirm_group_match(stmt_ids, [txn.id])
      else
        {:error, :bank_txn_mismatch}
      end
    end)
    |> Repo.transaction()
    |> case do
      {:ok, changes} -> {:ok, Map.fetch!(changes, doc_key)}
      {:error, _step, %Ecto.Changeset{} = cs, _} -> {:error, cs}
      {:error, _step, reason, _} -> {:error, reason}
    end
    |> Accounting.map_period_closed()
  end

  @doc """
  Match statement lines against book transactions whose totals differ — a
  statement net of a fee (card commission, bank charges) — by posting the
  difference to `diff_account` as a Journal dated the latest statement date,
  then matching lines + transactions + the new journal's bank transaction as
  one group. All in one database transaction.

  stmt_total − txn_total = the journal's bank-side amount (e.g. 98 − 100 =
  −2.00 fee), so the matched group always sums exactly.
  """
  def match_with_difference(stmt_ids, txn_ids, diff_account, company, user)
      when is_list(stmt_ids) and stmt_ids != [] and is_list(txn_ids) and txn_ids != [] do
    lines =
      from(sl in BankStatementLine,
        where: sl.id in ^stmt_ids,
        where: sl.company_id == ^company.id,
        where: is_nil(sl.match_group_id)
      )
      |> Repo.all()

    txns =
      from(t in Transaction,
        where: t.id in ^txn_ids,
        where: t.company_id == ^company.id,
        where: t.reconciled == false
      )
      |> Repo.all()

    stmt_total = Enum.reduce(lines, Decimal.new(0), &Decimal.add(&1.amount, &2))
    txn_total = Enum.reduce(txns, Decimal.new(0), &Decimal.add(&1.amount, &2))
    diff = Decimal.sub(stmt_total, txn_total)

    cond do
      length(lines) != length(stmt_ids) or length(txns) != length(txn_ids) or
          length(Enum.uniq_by(lines, & &1.account_id)) != 1 ->
        {:error, :invalid_selection}

      Decimal.eq?(diff, 0) ->
        {:error, :no_difference}

      not FullCircle.Authorization.can?(user, :create_journal, company) ->
        :not_authorise

      true ->
        do_match_with_difference(lines, txns, diff, diff_account, company, user)
    end
  end

  defp do_match_with_difference(lines, txns, diff, diff_account, company, user) do
    bank_account = Repo.get!(FullCircle.Accounting.Account, hd(lines).account_id)
    date = lines |> Enum.map(& &1.statement_date) |> Enum.max(Date)

    particulars =
      lines |> Enum.map(& &1.description) |> Enum.uniq() |> Enum.join("; ") |> String.slice(0, 230)

    attrs = %{
      "journal_date" => Date.to_iso8601(date),
      "company_id" => company.id,
      "transactions" => %{
        "0" => %{
          "account_name" => bank_account.name,
          "account_id" => bank_account.id,
          "amount" => Decimal.to_string(diff),
          "particulars" => particulars
        },
        "1" => %{
          "account_name" => diff_account.name,
          "account_id" => diff_account.id,
          "amount" => Decimal.to_string(Decimal.negate(diff)),
          "particulars" => particulars
        }
      }
    }

    stmt_ids = Enum.map(lines, & &1.id)
    txn_ids = Enum.map(txns, & &1.id)

    Ecto.Multi.new()
    |> FullCircle.JournalEntry.create_journal_multi(attrs, company, user)
    |> Ecto.Multi.run(:recon_match, fn _repo, %{create_journal: journal} ->
      case find_journal_transaction(journal.id, bank_account.id) do
        %Transaction{} = jtxn -> confirm_group_match(stmt_ids, txn_ids ++ [jtxn.id])
        nil -> {:error, :journal_txn_missing}
      end
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{create_journal: journal}} -> {:ok, journal}
      {:error, _step, %Ecto.Changeset{} = cs, _} -> {:error, cs}
      {:error, _step, reason, _} -> {:error, reason}
    end
    |> Accounting.map_period_closed()
  end

  def find_journal_transaction(journal_id, account_id) do
    find_doc_transaction(journal_id, account_id, "Journal")
  end

  def find_doc_transaction(doc_id, account_id, doc_type) do
    from(t in Transaction,
      where: t.doc_id == ^doc_id,
      where: t.account_id == ^account_id,
      where: t.doc_type == ^doc_type,
      limit: 1
    )
    |> Repo.one()
  end

  def get_account_by_name(name, com, user) do
    Accounting.get_account_by_name(name, com, user)
  end
end
