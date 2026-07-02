defmodule FullCircle.StatutoryConfig.DbEnv do
  @moduledoc false
  @behaviour FullCircle.PayScript.Env

  import Ecto.Query, warn: false

  alias FullCircle.{PayScript, Repo, StatutoryConfig}
  alias FullCircle.HR.{SalaryNote, SalaryType}
  alias FullCircle.PayScript.Error

  @impl true
  def lookup(state, table, value, column) do
    case StatutoryConfig.effective_table(state.company_id, table, state.date) do
      nil ->
        {:error, "no version of table '#{table}' effective on #{state.date}"}

      %{columns: cols, rows: rows} ->
        case Enum.find_index(cols, &(&1 == column)) do
          nil ->
            {:error, "unknown column '#{column}' in table '#{table}'"}

          idx ->
            row = Enum.find(rows, fn [from, to | _] -> value > from and value <= to end)
            {:ok, if(row, do: Enum.at(row, idx), else: 0.0)}
        end
    end
  end

  @impl true
  def ytd_sum(state, :code, keys) do
    {:ok, sum_notes(state, :code, keys)}
  end

  def ytd_sum(state, :type, keys) do
    {:ok, sum_notes(state, :type, keys)}
  end

  def ytd_sum(state, :name, keys) do
    {:ok, sum_notes(state, :name, keys)}
  end

  @impl true
  def calc(state, code) do
    case StatutoryConfig.effective_calc(state.company_id, code, state.date) do
      nil ->
        {:error, "no version of calc '#{code}' effective on #{state.date}"}

      %{script: script} ->
        case PayScript.eval(script, state.context, {__MODULE__, state}) do
          {:ok, dec} ->
            {:ok, Decimal.to_float(dec)}

          {:error, %Error{} = e} ->
            {:error, "in calc '#{code}': #{Exception.message(e)}"}
        end
    end
  end

  defp sum_notes(state, :code, keys) do
    from(sn in SalaryNote,
      join: st in SalaryType,
      on: st.id == sn.salary_type_id,
      where: sn.employee_id == ^state.employee_id,
      where: fragment("extract(year from ?) = ?", sn.note_date, ^state.pay_year),
      where: fragment("extract(month from ?) < ?", sn.note_date, ^state.pay_month),
      where: st.statutory_code in ^keys,
      select: coalesce(sum(sn.quantity * sn.unit_price), 0)
    )
    |> Repo.one()
    |> Decimal.to_float()
  end

  defp sum_notes(state, :type, keys) do
    from(sn in SalaryNote,
      join: st in SalaryType,
      on: st.id == sn.salary_type_id,
      where: sn.employee_id == ^state.employee_id,
      where: fragment("extract(year from ?) = ?", sn.note_date, ^state.pay_year),
      where: fragment("extract(month from ?) < ?", sn.note_date, ^state.pay_month),
      where: st.type in ^keys,
      select: coalesce(sum(sn.quantity * sn.unit_price), 0)
    )
    |> Repo.one()
    |> Decimal.to_float()
  end

  defp sum_notes(state, :name, keys) do
    from(sn in SalaryNote,
      join: st in SalaryType,
      on: st.id == sn.salary_type_id,
      where: sn.employee_id == ^state.employee_id,
      where: fragment("extract(year from ?) = ?", sn.note_date, ^state.pay_year),
      where: fragment("extract(month from ?) < ?", sn.note_date, ^state.pay_month),
      where: st.name in ^keys,
      select: coalesce(sum(sn.quantity * sn.unit_price), 0)
    )
    |> Repo.one()
    |> Decimal.to_float()
  end
end