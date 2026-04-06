defmodule FullCircle.BankReconciliation.LlmParser do
  @moduledoc """
  Uses an LLM API to parse bank statement files (CSV or PDF text).
  Splits large statements into batches to avoid model output limits.
  """

  alias FullCircle.BankReconciliation.LlmClient

  @system_prompt "You parse bank statements (CSV or PDF) into JSON. Return only valid JSON."

  @batch_size 100

  @pdf_prompt """
  You are a bank statement parser. The attached PDF is a bank statement.
  Extract ALL transaction lines and balances from it.

  Return ONLY a JSON object with this exact structure:
  {
    "opening_balance": number or null,
    "closing_balance": number or null,
    "transactions": [...]
  }

  IMPORTANT — Finding balances:
  - Look carefully for opening and closing balances
  - Opening balance: "Opening Balance", "Beginning Balance", "B/F", "Balance Brought Forward", "BAKI AWAL", or the first "Balance" column value
  - Closing balance: "Closing Balance", "Ending Balance", "C/F", "Balance Carried Forward", "BAKI AKHIR", or the last "Balance" column value
  - These are ALWAYS positive numbers representing the account balance
  - If the statement shows a running balance column, opening_balance is the first value and closing_balance is the last value

  Each transaction object must have exactly these fields:
  - "statement_date": date in "YYYY-MM-DD" format
  - "description": combine the transaction type/description with ALL reference columns into one string. Join non-empty values with " | ". Include company names, invoice numbers, payment references.
  - "cheque_no": cheque number string or null
  - "amount": number (positive for credits/deposits, negative for debits/withdrawals)

  Rules:
  - Extract EVERY transaction line — do not skip or summarize
  - Do NOT include opening/closing balance rows as transactions
  - Skip header rows and summary rows
  - Skip rows with zero amount
  - Return ONLY the JSON object, no markdown, no explanation
  """

  @first_batch_prompt """
  You are a bank statement parser. Extract ALL transaction lines and balances from the content below.
  The content may be CSV data or text extracted from a PDF bank statement.

  Return ONLY a JSON object with this exact structure:
  {
    "opening_balance": number or null,
    "closing_balance": number or null,
    "transactions": [...]
  }

  IMPORTANT — Finding balances:
  - Look carefully for opening and closing balances
  - Opening balance: "Opening Balance", "Beginning Balance", "B/F", "Balance Brought Forward", "BAKI AWAL", or the first "Balance" column value
  - Closing balance: "Closing Balance", "Ending Balance", "C/F", "Balance Carried Forward", "BAKI AKHIR", or the last "Balance" column value
  - These are ALWAYS positive numbers representing the account balance
  - If the statement shows a running balance column, opening_balance is the first value and closing_balance is the last value

  Each transaction object must have exactly these fields:
  - "statement_date": date in "YYYY-MM-DD" format
  - "description": combine the transaction type/description with ALL reference columns into one string. Join non-empty values with " | ". Include company names, invoice numbers, payment references.
  - "cheque_no": cheque number string or null
  - "amount": number (positive for credits/deposits, negative for debits/withdrawals)

  Rules:
  - Extract EVERY transaction line — do not skip or summarize
  - Do NOT include opening/closing balance rows as transactions
  - Skip header rows and summary rows
  - Skip rows with zero amount
  - Return ONLY the JSON object, no markdown, no explanation

  Content:
  """

  @continuation_prompt """
  You are a bank statement parser. Extract ALL transaction lines from the content below.
  This is a continuation of a bank statement — only extract transactions, no balances needed.

  Return ONLY a JSON array of transaction objects. Each object must have exactly these fields:
  - "statement_date": date in "YYYY-MM-DD" format
  - "description": combine the transaction type/description with ALL reference columns into one string. Join non-empty values with " | ". Include company names, invoice numbers, payment references.
  - "cheque_no": cheque number string or null
  - "amount": number (positive for credits/deposits, negative for debits/withdrawals)

  Rules:
  - Extract EVERY transaction line — do not skip or summarize
  - Skip header rows and summary rows
  - Skip rows with zero amount
  - Return ONLY the JSON array, no markdown, no explanation

  Content:
  """

  def parse(file_path, settings) do
    content =
      File.read!(file_path)
      |> String.split("\n")
      |> Enum.take(2000)
      |> Enum.join("\n")

    parse_content(content, settings)
  end

  def parse_pdf(pdf_path, settings) do
    pdf_base64 = pdf_path |> File.read!() |> Base.encode64()

    case LlmClient.call_with_pdf(settings, @system_prompt, @pdf_prompt, pdf_base64) do
      {:ok, text, usage} -> parse_first_response(text, usage)
      {:error, reason} -> {:error, reason}
    end
  end

  def parse_content(content, settings) do
    lines = String.split(content, "\n")

    # Separate header (first 20 lines) from data
    {header_lines, data_lines} = Enum.split(lines, 20)
    header = Enum.join(header_lines, "\n")

    # Split data lines into batches
    batches = Enum.chunk_every(data_lines, @batch_size)

    case batches do
      [] ->
        # Tiny file — send as one request
        call_first_batch(content, settings)

      [only_batch] ->
        # Small file — send header + all data as one request
        call_first_batch(header <> "\n" <> Enum.join(only_batch, "\n"), settings)

      [first | rest] ->
        # Large file — process in batches
        case call_first_batch(header <> "\n" <> Enum.join(first, "\n"), settings) do
          {:ok, "llm", first_lines, first_usage, balances} ->
            process_remaining_batches(rest, settings, first_lines, first_usage, balances)

          error ->
            error
        end
    end
  end

  defp call_first_batch(content, settings) do
    case LlmClient.call(settings, @system_prompt, @first_batch_prompt <> content) do
      {:ok, text, usage} -> parse_first_response(text, usage)
      {:error, reason} -> {:error, reason}
    end
  end

  defp process_remaining_batches([], _settings, all_lines, total_usage, balances) do
    {:ok, "llm", all_lines, total_usage, balances}
  end

  defp process_remaining_batches([batch | rest], settings, all_lines, total_usage, balances) do
    content = Enum.join(batch, "\n")

    case LlmClient.call(settings, @system_prompt, @continuation_prompt <> content) do
      {:ok, text, usage} ->
        case parse_continuation_response(text) do
          {:ok, new_lines} ->
            merged_usage = merge_usage(total_usage, usage)
            process_remaining_batches(rest, settings, all_lines ++ new_lines, merged_usage, balances)

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp merge_usage(a, b) do
    %{
      a
      | input_tokens: a.input_tokens + b.input_tokens,
        output_tokens: a.output_tokens + b.output_tokens,
        total_tokens: a.total_tokens + b.total_tokens,
        cost_estimate:
          if(a.cost_estimate && b.cost_estimate,
            do: Float.round(a.cost_estimate + b.cost_estimate, 6),
            else: a.cost_estimate || b.cost_estimate
          )
    }
  end

  # --- Response parsing ---

  defp parse_first_response(text, usage) do
    require Logger
    Logger.info("LLM batch response: #{byte_size(text)} bytes")

    case decode_json(text) do
      {:ok, %{"transactions" => items} = resp} when is_list(items) ->
        lines = items |> Enum.map(&normalize_line/1) |> Enum.reject(&is_nil/1)

        balances = %{
          opening_balance: parse_balance(resp["opening_balance"]),
          closing_balance: parse_balance(resp["closing_balance"])
        }

        {:ok, "llm", lines, usage, balances}

      {:ok, items} when is_list(items) ->
        lines = items |> Enum.map(&normalize_line/1) |> Enum.reject(&is_nil/1)
        {:ok, "llm", lines, usage, %{opening_balance: nil, closing_balance: nil}}

      {:ok, _} ->
        {:error, "LLM returned unexpected JSON format"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_continuation_response(text) do
    require Logger
    Logger.info("LLM continuation response: #{byte_size(text)} bytes")

    case decode_json(text) do
      {:ok, items} when is_list(items) ->
        lines = items |> Enum.map(&normalize_line/1) |> Enum.reject(&is_nil/1)
        {:ok, lines}

      {:ok, %{"transactions" => items}} when is_list(items) ->
        lines = items |> Enum.map(&normalize_line/1) |> Enum.reject(&is_nil/1)
        {:ok, lines}

      {:ok, _} ->
        {:error, "LLM returned unexpected JSON format for continuation batch"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode_json(text) do
    require Logger

    cleaned =
      text
      |> String.replace(~r/```json\s*/, "")
      |> String.replace(~r/```\s*/, "")
      |> String.trim()

    # Extract JSON candidates from LLM response (may contain thinking/reasoning text)
    obj_match = case Regex.run(~r/(\{[\s\S]*\})/s, cleaned) do
      [_, m] -> m
      _ -> nil
    end

    arr_match = case Regex.run(~r/(\[[\s\S]*\])/s, cleaned) do
      [_, m] -> m
      _ -> nil
    end

    # Try candidates in order: object first (preserves balances), then array, then wrap as array
    candidates =
      Enum.reject(
        [obj_match, arr_match, if(obj_match, do: "[" <> obj_match <> "]")],
        &is_nil/1
      )

    Enum.reduce_while(candidates, {:error, "No JSON found in LLM response"}, fn candidate, _acc ->
      case Jason.decode(candidate) do
        {:ok, result} -> {:halt, {:ok, result}}
        {:error, _} -> {:cont, {:error, "Failed to parse LLM response as JSON"}}
      end
    end)
  end

  # --- Normalization helpers ---

  defp parse_balance(nil), do: nil
  defp parse_balance(n) when is_integer(n), do: Decimal.new(n)
  defp parse_balance(n) when is_float(n), do: Decimal.from_float(n)

  defp parse_balance(str) when is_binary(str) do
    case Decimal.parse(String.replace(str, ",", "")) do
      {d, _} -> d
      :error -> nil
    end
  end

  defp parse_balance(_), do: nil

  defp normalize_line(item) when is_map(item) do
    with {:ok, date} <- parse_date(item["statement_date"]),
         amount when not is_nil(amount) <- parse_amount(item["amount"]) do
      if Decimal.eq?(amount, 0) do
        nil
      else
        description = to_string(item["description"] || "")

        description =
          case item["reference"] do
            ref when is_binary(ref) and ref != "" -> description <> " | " <> ref
            _ -> description
          end

        %{
          statement_date: date,
          description: description,
          cheque_no: if(item["cheque_no"], do: to_string(item["cheque_no"])),
          amount: amount,
          reference: nil
        }
      end
    else
      _ -> nil
    end
  end

  defp normalize_line(_), do: nil

  defp parse_date(nil), do: :error
  defp parse_date(str) when is_binary(str), do: Date.from_iso8601(str)

  defp parse_amount(n) when is_integer(n), do: Decimal.new(n)
  defp parse_amount(n) when is_float(n), do: Decimal.from_float(n)

  defp parse_amount(str) when is_binary(str) do
    case Decimal.parse(String.replace(str, ",", "")) do
      {d, _} -> d
      :error -> nil
    end
  end

  defp parse_amount(_), do: nil
end
