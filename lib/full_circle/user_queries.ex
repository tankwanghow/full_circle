defmodule FullCircle.UserQueries do
  import Ecto.Query, warn: false
  import FullCircle.Helpers
  import FullCircle.Authorization

  # User-authored SQL runs unmodified against the reporting repo, and
  # exec_query_row_col/3 materialises every row. Without a ceiling one careless
  # query OOMs the container — which, with no restart policy on the box, then
  # stays down. Fail loudly instead, with an actionable message.
  @row_limit 50_000

  def execute(sql_string, com, user) do
    case can?(user, :execute_query, com) do
      true ->
        sql_string
        |> fill_company_name(com.id)
        |> bound_rows()
        |> exec_query_row_col(FullCircle.QueryRepo)
        |> guard_row_limit()

      false ->
        {:error, :not_authorise}
    end
  end

  # A CTE or an ORDER BY survives being wrapped; a second statement does not,
  # which is the point — it fails as a syntax error rather than running.
  defp bound_rows(qry) do
    inner = Regex.replace(~r/;\s*\z/, String.trim(qry), "")
    "SELECT * FROM (#{inner}) AS fc_bounded LIMIT #{@row_limit + 1}"
  end

  defp guard_row_limit({cols, rows}) do
    if length(rows) > @row_limit do
      raise "Query returned more than #{@row_limit} rows. " <>
              "Add a WHERE clause or your own LIMIT to narrow it."
    end

    {cols, rows}
  end

  def fill_company_name(qry, com_id) do
    Regex.replace(~r/[\s+|\n+\^](fct_)(\w+)[\s+|\n+]/, qry <> " ", fn _full, st, nd ->
      " #{st}#{nd}('#{com_id}') "
    end)
  end

  def generate_sql(prompt, llm_settings, opts \\ []) do
    FullCircle.UserQueries.SqlGenerator.generate(prompt, llm_settings, opts)
  end
end
