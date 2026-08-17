defmodule FullCircle.UserQueries.SqlGenerator do
  @moduledoc """
  Drafts a SELECT for Queries Listing from a plain-language prompt.
  The SQL is never executed here — the user reviews it on the form.
  """

  alias FullCircle.BankReconciliation.LlmClient
  alias FullCircle.Repo

  @hidden_fct ~w(fct_users fct_company_user fct_logs fct_gapless_doc_ids)
  @allowed_sources ~w(generate_series)

  @forbidden ~r/\b(insert|update|delete|drop|alter|truncate|create|grant|revoke|copy|call|execute)\b/i

  def generate(prompt, settings, opts \\ []) do
    prompt = String.trim(prompt || "")

    if prompt == "" do
      {:error, "Describe the query first."}
    else
      client = Keyword.get(opts, :client, &LlmClient.call/3)
      catalog = fetch_opt(opts, :catalog, &catalog/0)
      columns = fetch_opt(opts, :columns, &column_catalog/0)
      accounts = accounts_opt(opts)
      dry_run_fun = dry_run_fun(opts)
      system = system_prompt(catalog, columns, accounts)

      with {:ok, text, _usage} <- client.(settings, system, prompt),
           {:ok, sql} <- extract_sql(text),
           :ok <- validate_sql(sql, catalog) do
        case dry_run_fun.(sql) do
          :ok ->
            {:ok, sql}

          {:error, pg_error} ->
            repair(client, settings, system, prompt, sql, pg_error, catalog)
        end
      end
    end
  end

  def catalog do
    {:ok, %{rows: rows}} =
      Repo.query("SELECT proname FROM pg_proc WHERE proname LIKE 'fct_%' ORDER BY 1")

    rows
    |> Enum.map(fn [name] -> name end)
    |> Enum.reject(&(&1 in @hidden_fct))
  end

  @doc """
  Stored columns for each fct_* (from the SETOF table type).
  Virtual LiveView fields such as invoice_amount never appear.
  """
  def column_catalog do
    {:ok, %{rows: rows}} =
      Repo.query("""
      SELECT p.proname, a.attname
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
      JOIN pg_type ret ON ret.oid = p.prorettype
      JOIN pg_class c ON c.oid = ret.typrelid
      JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
      WHERE n.nspname = 'public'
        AND p.proname LIKE 'fct_%'
      ORDER BY p.proname, a.attnum
      """)

    rows
    |> Enum.reject(fn [name, _] -> name in @hidden_fct end)
    |> Enum.group_by(fn [name, _] -> name end, fn [_, col] -> col end)
    |> Enum.sort_by(fn {name, _} -> name end)
    |> Enum.map(fn {name, cols} -> "#{name}: #{Enum.join(cols, ", ")}" end)
    |> Enum.join("\n")
  end

  def account_directory(company_id) do
    import Ecto.Query

    from(a in FullCircle.Accounting.Account,
      where: a.company_id == ^company_id,
      select: {a.name, a.account_type},
      order_by: [a.account_type, a.name]
    )
    |> Repo.all()
    |> Enum.map_join(", ", fn {name, type} -> "#{name} (#{type})" end)
  end

  def dry_run(sql, company_id) do
    filled = FullCircle.UserQueries.fill_company_name(sql, company_id)

    case Repo.query("EXPLAIN #{filled}") do
      {:ok, _} ->
        :ok

      {:error, %{postgres: %{message: msg}}} ->
        {:error, msg}

      {:error, err} ->
        {:error, Exception.message(err)}
    end
  end

  def extract_sql(text) when is_binary(text) do
    text = String.trim(text)

    cond do
      String.contains?(text, "```") ->
        case Regex.run(~r/```(?:sql)?\s*([\s\S]*?)```/i, text) do
          [_, sql] -> ok_sql(sql)
          _ -> {:error, "Could not find SQL in the model response."}
        end

      String.match?(text, ~r/^\s*(with\s+[a-zA-Z_][\w]*\s+as\b|select)\b/i) ->
        ok_sql(text)

      true ->
        case Regex.run(~r/((?:with\s+[a-zA-Z_][\w]*\s+as\b|select)\b[\s\S]*)/i, text) do
          [_, sql] -> ok_sql(sql)
          _ -> {:error, "Could not find SQL in the model response."}
        end
    end
  end

  def extract_sql(_), do: {:error, "Could not find SQL in the model response."}

  def validate_sql(sql, catalog) when is_binary(sql) and is_list(catalog) do
    stripped = strip_comments(sql)
    catalog_set = MapSet.new(catalog)
    allowed = MapSet.new(@allowed_sources ++ cte_names(stripped))

    cond do
      not String.match?(stripped, ~r/^\s*(with|select)\b/i) ->
        {:error, "Only SELECT queries are allowed."}

      Regex.match?(@forbidden, stripped) ->
        {:error, "Only SELECT queries are allowed."}

      true ->
        stripped
        |> relation_names()
        |> Enum.reduce_while(:ok, fn name, :ok ->
          cond do
            name in allowed ->
              {:cont, :ok}

            String.starts_with?(name, "fct_") and MapSet.member?(catalog_set, name) ->
              {:cont, :ok}

            String.starts_with?(name, "fct_") ->
              {:halt, {:error, "#{name} is not an available fct_ function."}}

            true ->
              {:halt,
               {:error, "Use fct_ functions only (got #{name}). Do not query raw tables."}}
          end
        end)
    end
  end

  defp ok_sql(sql) do
    sql = sql |> String.trim() |> String.trim_trailing(";")

    if sql == "" do
      {:error, "Could not find SQL in the model response."}
    else
      {:ok, sql}
    end
  end

  defp strip_comments(sql) do
    sql
    |> String.replace(~r/--[^\n]*/, "")
    |> String.replace(~r/\/\*[\s\S]*?\*\//, "")
  end

  defp cte_names(sql) do
    Regex.scan(~r/(?:with|,)\s*([a-zA-Z_][\w]*)\s+as\s*\(/i, sql)
    |> Enum.map(fn [_, name] -> String.downcase(name) end)
  end

  defp relation_names(sql) do
    Regex.scan(~r/\b(?:from|join)\s+(?!\()([a-zA-Z_][\w]*)/i, sql)
    |> Enum.map(fn [_, name] -> String.downcase(name) end)
  end

  def schema_card do
    :full_circle
    |> :code.priv_dir()
    |> Path.join("user_queries/schema_card.md")
    |> File.read!()
  end

  defp system_prompt(catalog, columns, accounts) do
    names = Enum.join(catalog, ", ")

    accounts_block =
      if accounts in [nil, ""] do
        ""
      else
        """

        Accounts in THIS company (use these exact names if you filter by account;
        never invent 'Trade Debtors' or other textbook names):
        #{accounts}
        """
      end

    """
    You write PostgreSQL SELECT statements for Full Circle ERP saved queries.

    Return ONLY SQL (a SELECT or WITH ... SELECT). No explanation.

    Rules:
    - SELECT / WITH only. Never INSERT, UPDATE, DELETE, DDL.
    - Use only the fct_ functions listed below, with no arguments.
    - Use ONLY the stored columns listed. Never invent names (invoice_amount,
      pay_slip_amount, detail amount/tax_amount are NOT columns).
    - "Trade debtors / customer balances as of DATE" = SUM(fct_transactions.amount)
      by fct_contacts, not a GL account named Trade Debtors.

    Available functions: #{names}

    Stored columns:
    #{columns}
    #{accounts_block}

    #{schema_card()}
    """
  end

  defp repair(client, settings, system, prompt, sql, pg_error, catalog) do
    repair_prompt = """
    Original request:
    #{prompt}

    Your previous SQL failed Postgres with:
    #{pg_error}

    Previous SQL:
    #{sql}

    Fix the SQL using only stored columns from the system prompt. Return only SQL.
    """

    with {:ok, text, _usage} <- client.(settings, system, repair_prompt),
         {:ok, fixed} <- extract_sql(text),
         :ok <- validate_sql(fixed, catalog) do
      {:ok, fixed}
    end
  end

  defp fetch_opt(opts, key, default_fun) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> value
      :error -> default_fun.()
    end
  end

  defp accounts_opt(opts) do
    case Keyword.fetch(opts, :accounts) do
      {:ok, value} ->
        value

      :error ->
        case Keyword.get(opts, :company_id) do
          nil -> ""
          company_id -> account_directory(company_id)
        end
    end
  end

  defp dry_run_fun(opts) do
    case Keyword.fetch(opts, :dry_run) do
      {:ok, fun} ->
        fun

      :error ->
        case Keyword.get(opts, :company_id) do
          nil -> fn _sql -> :ok end
          company_id -> fn sql -> dry_run(sql, company_id) end
        end
    end
  end
end
