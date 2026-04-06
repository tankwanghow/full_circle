defmodule FullCircle.BankReconciliation.LlmMatcher do
  @moduledoc """
  Uses an LLM to match unmatched bank statement lines with book transactions.
  Returns suggestions in the same format as auto_match: [{stmt_ids, txn_ids, score}].
  """

  alias FullCircle.BankReconciliation.LlmClient

  @system_prompt "You are a bank reconciliation assistant. Match bank statement lines to book transactions. Return only valid JSON."

  @user_prompt """
  Match bank statement lines to book transactions for bank reconciliation.

  Return ONLY a JSON array of match groups. Each group:
  {"stmt_ids": ["id1", ...], "txn_ids": ["id1", ...], "confidence": 0-100, "reason": "brief reason"}

  IMPORTANT — Many-to-one and many-to-many matching:
  - A SINGLE book transaction (e.g. a Receipt for $10,000) may correspond to MULTIPLE bank statement lines
    (e.g. 3 cheque deposits of $3,000 + $4,000 + $3,000 that sum to $10,000).
  - Similarly, multiple book transactions may match one bank line.
  - Group them together when the SUM of bank amounts equals the SUM of book amounts.

  Matching strategy:
  1. First, find 1:1 matches where a single bank line amount equals a single book transaction amount.
     Use date proximity and description/particulars similarity to pick the best match.
  2. Then, look for many-to-one groups: find sets of bank lines whose amounts sum to a single book transaction.
     These typically share the same or similar dates and relate to the same party/description.
  3. Also look for one-to-many: a single bank line matching multiple book transactions that sum to its amount.
  4. Use cheque_no matching: bank cheque_no often matches part of the book doc_no.
  5. Use description matching: bank descriptions often contain the counterparty name found in book particulars.

  Rules:
  - The sum of stmt amounts in a group MUST equal the sum of txn amounts in that group.
  - Each item should appear in at most one group.
  - Only include matches with confidence >= 50.
  - Return empty array [] if no good matches found.
  - Return ONLY the JSON array, no markdown, no explanation.

  BANK STATEMENT LINES (unmatched):
  """

  def match(unmatched_stmts, unmatched_txns, settings) do
    if unmatched_stmts == [] or unmatched_txns == [] do
      {:ok, [], nil}
    else
      prompt = build_prompt(unmatched_stmts, unmatched_txns)

      case LlmClient.call(settings, @system_prompt, prompt) do
        {:ok, text, usage} -> parse_match_response(text, unmatched_stmts, unmatched_txns, usage)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp build_prompt(stmts, txns) do
    stmt_lines =
      Enum.map_join(stmts, "\n", fn s ->
        "  {\"id\": \"#{s.id}\", \"date\": \"#{s.statement_date}\", \"amount\": #{s.amount}, \"cheque_no\": #{if s.cheque_no, do: "\"#{s.cheque_no}\"", else: "null"}, \"description\": \"#{escape(s.description)}\", \"reference\": #{if s.reference, do: "\"#{escape(s.reference)}\"", else: "null"}}"
      end)

    txn_lines =
      Enum.map_join(txns, "\n", fn t ->
        "  {\"id\": \"#{t.id}\", \"date\": \"#{t.doc_date}\", \"amount\": #{t.amount}, \"doc_no\": \"#{t.doc_no}\", \"doc_type\": \"#{t.doc_type}\", \"particulars\": \"#{escape(t.particulars || "")}\"}"
      end)

    @user_prompt <> stmt_lines <> "\n\nBOOK TRANSACTIONS (unreconciled):\n" <> txn_lines
  end

  defp escape(str) do
    str
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
    |> String.replace("\n", " ")
  end

  defp parse_match_response(text, stmts, txns, usage) do
    json_text =
      text
      |> String.replace(~r/```json\s*/, "")
      |> String.replace(~r/```\s*/, "")
      |> String.trim()

    # Extract JSON array - handle cases where LLM adds thinking text
    json_text =
      case Regex.run(~r/\[[\s\S]*\]/, json_text) do
        [match] -> match
        _ -> json_text
      end

    valid_stmt_ids = MapSet.new(stmts, & &1.id)
    valid_txn_ids = MapSet.new(txns, & &1.id)

    case Jason.decode(json_text) do
      {:ok, groups} when is_list(groups) ->
        matches =
          groups
          |> Enum.map(&normalize_group(&1, valid_stmt_ids, valid_txn_ids))
          |> Enum.reject(&is_nil/1)
          |> deduplicate_matches()

        {:ok, matches, usage}

      {:ok, _} ->
        {:ok, [], usage}

      {:error, _} ->
        {:ok, [], usage}
    end
  end

  defp normalize_group(group, valid_stmt_ids, valid_txn_ids) when is_map(group) do
    stmt_ids =
      (group["stmt_ids"] || [])
      |> Enum.filter(&MapSet.member?(valid_stmt_ids, &1))

    txn_ids =
      (group["txn_ids"] || [])
      |> Enum.filter(&MapSet.member?(valid_txn_ids, &1))

    confidence = group["confidence"] || 50

    if stmt_ids != [] and txn_ids != [] and confidence >= 50 do
      {stmt_ids, txn_ids, confidence}
    else
      nil
    end
  end

  defp normalize_group(_, _, _), do: nil

  # Ensure no item appears in multiple groups
  defp deduplicate_matches(matches) do
    {result, _, _} =
      Enum.reduce(matches, {[], MapSet.new(), MapSet.new()}, fn {stmt_ids, txn_ids, score}, {acc, used_stmts, used_txns} ->
        clean_stmts = Enum.reject(stmt_ids, &MapSet.member?(used_stmts, &1))
        clean_txns = Enum.reject(txn_ids, &MapSet.member?(used_txns, &1))

        if clean_stmts != [] and clean_txns != [] do
          new_used_stmts = Enum.reduce(clean_stmts, used_stmts, &MapSet.put(&2, &1))
          new_used_txns = Enum.reduce(clean_txns, used_txns, &MapSet.put(&2, &1))
          {[{clean_stmts, clean_txns, score} | acc], new_used_stmts, new_used_txns}
        else
          {acc, used_stmts, used_txns}
        end
      end)

    Enum.reverse(result)
  end
end
