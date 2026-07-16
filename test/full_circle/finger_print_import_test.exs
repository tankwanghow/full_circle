defmodule FullCircle.HR.FingerPrintImportTest do
  use ExUnit.Case, async: true

  alias FullCircle.HR.FingerPrintImport

  # Minimal stand-in for the "Att.log report" sheet:
  # row 0: title, row 1: blank, row 2: date range at index 2,
  # row 3: day-number header, row 4+: pairs of [info-row, attendance-row].
  defp sample_rows do
    info = [
      "ID:",
      "",
      "7",
      "",
      "",
      "",
      "",
      "",
      "Name:",
      "",
      "Gurung Bir Bahadur",
      "",
      "Dept:",
      "",
      "Chicken Farm",
      "",
      "",
      "",
      ""
    ]

    # 2 days of punches; day 1 has 4 punches, day 2 has 2 punches + a <10min dup to drop
    att = ["07:5512:0112:5417:01", "07:5107:5512:01"]

    [
      ["Attendance Record Report"],
      [],
      ["Att. Time", "", "2026-01-01 ~ 2026-01-02"],
      [1.0, 2.0],
      info,
      att
    ]
  end

  test "parse_file_rows/1 splits concatenated times, dedups <10min, flags IN/OUT positionally" do
    [d1, d2] =
      FingerPrintImport.parse_file_rows(sample_rows())
      |> Enum.group_by(&(&1.punch_time_local |> NaiveDateTime.to_date()))
      |> Enum.sort_by(fn {d, _} -> d end)
      |> Enum.map(fn {_d, list} -> list end)

    # Day 1: 4 punches -> 1_IN_1,1_OUT_1,2_IN_2,2_OUT_2
    assert Enum.map(d1, & &1.flag) == ["1_IN_1", "1_OUT_1", "2_IN_2", "2_OUT_2"]

    assert Enum.map(d1, & &1.stamp) ==
             [~T[07:55:00], ~T[12:01:00], ~T[12:54:00], ~T[17:01:00]]

    # Day 2: 07:51 then 07:55 (<10min, dropped) then 12:01 -> two punches
    assert Enum.map(d2, & &1.stamp) == [~T[07:51:00], ~T[12:01:00]]
    assert Enum.map(d2, & &1.flag) == ["1_IN_1", "1_OUT_1"]

    # punch_card_id is the canonical "<id>.<name>" key (department excluded)
    assert hd(d1).punch_card_id == "7.Gurung Bir Bahadur"
    assert hd(d1)[:Name] == "Gurung Bir Bahadur"
  end

  defp file_rows(name_id_dept, day_cells, range) do
    [name, id, dept] = name_id_dept

    info = [
      "ID:",
      "",
      id,
      "",
      "",
      "",
      "",
      "",
      "Name:",
      "",
      name,
      "",
      "",
      "",
      "",
      "",
      "",
      "Dept:",
      dept
    ]

    [
      ["Attendance Record Report"],
      [],
      ["Att. Time", "", range],
      Enum.map(1..length(day_cells), &(&1 / 1)),
      info,
      day_cells
    ]
  end

  test "parse_files_rows/1 concatenates punches from both machine files" do
    f1 =
      file_rows(
        ["Gurung Bir Bahadur", "7", "Chicken Farm"],
        ["07:5512:01"],
        "2026-01-01 ~ 2026-01-01"
      )

    f2 = file_rows(["Linda Santika", "4", "Office"], ["08:0017:00"], "2026-01-01 ~ 2026-01-01")

    {:ok, attrs} = FingerPrintImport.parse_files_rows([f1, f2])

    cards = attrs |> Enum.map(& &1.punch_card_id) |> Enum.uniq() |> Enum.sort()
    assert cards == ["4.Linda Santika", "7.Gurung Bir Bahadur"]
  end

  test "parse_files_rows/1 rejects files covering different months" do
    f1 = file_rows(["A", "1", "X"], ["07:5512:01"], "2026-01-01 ~ 2026-01-31")
    f2 = file_rows(["B", "2", "Y"], ["07:5512:01"], "2026-02-01 ~ 2026-02-28")

    assert {:error, {:date_range_mismatch, ranges}} =
             FingerPrintImport.parse_files_rows([f1, f2])

    assert {~D[2026-01-01], ~D[2026-01-31]} in ranges
    assert {~D[2026-02-01], ~D[2026-02-28]} in ranges
  end
end
