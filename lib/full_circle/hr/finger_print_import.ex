defmodule FullCircle.HR.FingerPrintImport do
  @moduledoc """
  Pure parsing of a fingerprint machine's "Att.log report" sheet rows into
  attendance attribute maps. No IO, no DB. The LiveView handles file reading
  (xlsx_reader) and employee/company enrichment.
  """

  @doc """
  Parse one file's sheet `rows` (list of row-lists) into a flat list of punch maps:
  `%{stamp: Time, flag: String|nil, ID:, Name:, Department:, punch_card_id:, punch_time_local:}`.
  """
  def parse_file_rows(rows) do
    date_range = Enum.at(rows, 2) |> Enum.at(2) |> extract_date_range()

    rows
    |> Enum.drop(4)
    |> Enum.chunk_every(2)
    |> Enum.map(fn
      [info, att] -> parse_employee_block(info, att, date_range)
      [_info] -> []
    end)
    |> List.flatten()
  end

  @doc """
  Extract the `2026-01-01 ~ 2026-01-31` date span from a file's row-2 cell as
  `{from_date, to_date}`.
  """
  def file_date_range(rows) do
    [from | _] = dr = Enum.at(rows, 2) |> Enum.at(2) |> extract_date_range()
    {from, List.last(dr)}
  end

  defp parse_employee_block(info, att, date_range) do
    Enum.map(att, fn cell ->
      Regex.scan(~r/\d{2}:\d{2}/, to_string(cell))
      |> List.flatten()
      |> Enum.map(fn time_str ->
        [hour, minute] = String.split(time_str, ":") |> Enum.map(&String.to_integer/1)
        Time.new!(hour, minute, 0)
      end)
    end)
    |> Enum.zip(date_range)
    |> Enum.map(fn x -> filter_times_n_split_to_map(x, info) end)
    |> List.flatten()
  end

  defp extract_date_range(date_line) do
    [start_date, end_date] =
      Regex.scan(~r/\d{4}-\d{2}-\d{2}/, to_string(date_line))
      |> List.flatten()
      |> Enum.map(&Date.from_iso8601!/1)

    Date.range(start_date, end_date) |> Enum.to_list()
  end

  defp filter_times_n_split_to_map({times, dt}, info) do
    info = Enum.reject(info, fn x -> x == "" end)

    times
    |> Enum.reduce({[], nil}, fn time, {acc, last_time} ->
      if last_time && Time.diff(time, last_time, :second) < 600 do
        {acc, last_time}
      else
        {[time | acc], time}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
    |> fill_flags_to_map()
    |> Enum.map(fn x ->
      Map.merge(x, %{
        ID: Enum.at(info, 1),
        Name: Enum.at(info, 3),
        Department: Enum.at(info, 5),
        punch_card_id:
          "#{Enum.at(info, 3)}.#{Enum.at(info, 1)}.#{Enum.at(info, 5)}"
          |> String.replace(" ", ""),
        punch_time_local: NaiveDateTime.new!(dt, x.stamp)
      })
    end)
  end

  def fill_flags_to_map(tl) do
    Enum.map(Enum.with_index(tl, 1), fn {t, index} ->
      cond do
        index == 1 -> %{stamp: t, flag: "1_IN_1"}
        index == 2 -> %{stamp: t, flag: "1_OUT_1"}
        index == 3 -> %{stamp: t, flag: "2_IN_2"}
        index == 4 -> %{stamp: t, flag: "2_OUT_2"}
        index == 5 -> %{stamp: t, flag: "3_IN_3"}
        index == 6 -> %{stamp: t, flag: "3_OUT_3"}
        true -> %{stamp: t, flag: nil}
      end
    end)
  end
end
