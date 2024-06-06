defmodule FullCircle.UserQueries do
  import Ecto.Query, warn: false
  import FullCircle.Helpers
  import FullCircle.Authorization

  def execute(sql_string, com, user) do
    case can?(user, :execute_query, com) do
      true ->
        exec_query_row_col(fill_company_name(sql_string, com.id), FullCircle.QueryRepo)

      false ->
        {:error, :not_authorise}
    end
  end

  def fill_company_name(qry, com_id) do
    Regex.replace(~r/[\s+](fct_)(\w+)[\s+|\n+|$]/, qry, fn _full, st, nd -> " #{st}#{nd}('#{com_id}') " end)
  end
end
