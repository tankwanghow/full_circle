defmodule FullCircle.BankReconciliation.AutoMatcher do
  @moduledoc """
  Greedy 1:1 auto-matching of bank statement lines to book transactions.
  Matches on equal amount with date proximity and bank cheque references.
  """

  @min_score 10

  @bank_cheque_re ~r/\|\s*(\d{4,7})\s+(PBB|RHB|MBB|RHBI|PIBB|PBIB|MBIS|CTBB|HLBB|HLB|AMMB|CIMB|CIMBIB)\s*\|/i

  @bank_aliases %{
    "PBB" => ["PBB"],
    "RHB" => ["RHB", "RHBI"],
    "MBB" => ["MBB"],
    "RHBI" => ["RHBI", "RHB"],
    "PIBB" => ["PIBB", "PBIB"],
    "PBIB" => ["PBIB", "PIBB"],
    "MBIS" => ["MBIS"],
    "CTBB" => ["CTBB", "CIMB", "CIMBIB"],
    "CIMB" => ["CIMB", "CIMBIB", "CTBB"],
    "CIMBIB" => ["CIMBIB", "CIMB", "CTBB"],
    "HLBB" => ["HLBB", "HLB"],
    "HLB" => ["HLB", "HLBB"],
    "AMMB" => ["AMMB", "AMBANK", "AM BANK"]
  }

  def match(stmts, txns) do
    greedy_match(stmts, txns)
  end

  @doc false
  def score(stmt, txn), do: match_score(stmt, txn)

  defp greedy_match(stmts, txns) do
    candidates =
      for stmt <- stmts, txn <- txns, Decimal.eq?(stmt.amount, txn.amount) do
        score = match_score(stmt, txn)
        {stmt, txn, score}
      end
      |> Enum.filter(fn {_, _, score} -> score >= @min_score end)

    candidates
    |> Enum.sort_by(fn {stmt, txn, score} ->
      {-score, abs(Date.diff(stmt.date, txn.date)), stmt.id, txn.id}
    end)
    |> Enum.map(fn {stmt, txn, score} -> {stmt.id, txn.id, score} end)
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

    date_score + reference_score(stmt, txn)
  end

  defp reference_score(stmt, txn) do
    texts = reference_texts(txn)

    cond do
      bank_cheque = extract_bank_cheque(stmt.description) ->
        if bank_cheque_in_texts?(bank_cheque, texts), do: 50, else: 0

      stmt.cheque_no && bank_cheque_number?(stmt.cheque_no) &&
          Enum.any?(texts, &String.contains?(&1, stmt.cheque_no)) ->
        50

      stmt.cheque_no && txn.doc_no && String.contains?(txn.doc_no, stmt.cheque_no) ->
        50

      true ->
        0
    end
  end

  defp reference_texts(txn) do
    [txn.doc_no, Map.get(txn, :particulars)]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&String.upcase/1)
  end

  defp extract_bank_cheque(description) when is_binary(description) do
    case Regex.run(@bank_cheque_re, description) do
      [_, num, bank] -> {num, normalize_bank(bank)}
      _ -> nil
    end
  end

  defp extract_bank_cheque(_), do: nil

  defp bank_cheque_in_texts?({num, bank}, texts) do
    Enum.any?(texts, fn text ->
      bank_aliases(bank) |> Enum.any?(fn code -> String.contains?(text, num) and String.contains?(text, code) end)
    end)
  end

  defp bank_cheque_number?(cheque_no) when is_binary(cheque_no) do
    Regex.match?(~r/^[1-9]\d{3,6}$/, cheque_no)
  end

  defp bank_cheque_number?(_), do: false

  defp normalize_bank(bank), do: bank |> String.upcase() |> String.trim()

  defp bank_aliases(bank) do
    Map.get(@bank_aliases, normalize_bank(bank), [normalize_bank(bank)])
  end
end