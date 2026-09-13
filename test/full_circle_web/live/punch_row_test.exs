defmodule FullCircleWeb.PunchRowTest do
  use FullCircle.DataCase, async: true

  alias FullCircleWeb.Helpers

  @company %{timezone: "Asia/Kuala_Lumpur"}

  defp entry(iso, id),
    do: [Timex.parse!(iso, "{RFC3339}"), id, "Draft", "x", "", ""]

  test "a four punch day still renders six slots, as today" do
    list = [
      entry("2026-05-05T07:00:00+08:00", "a"),
      entry("2026-05-05T12:00:00+08:00", "b"),
      entry("2026-05-05T13:00:00+08:00", "c"),
      entry("2026-05-05T17:00:00+08:00", "d")
    ]

    slots = Helpers.punch_slots(list, @company)
    assert length(slots) == 6
    assert Enum.count(slots, fn {time, _, _, _, _, _} -> time != nil end) == 4
  end

  test "a six punch day renders seven slots, six filled plus one blank" do
    list =
      for {h, i} <- Enum.with_index(~w(07 09 10 12 13 17)) do
        entry("2026-05-05T#{h}:00:00+08:00", "id#{i}")
      end

    slots = Helpers.punch_slots(list, @company)
    assert length(slots) == 7
    assert Enum.count(slots, fn {time, _, _, _, _, _} -> time != nil end) == 6
    assert Enum.count(slots, fn {time, _, _, _, _, _} -> time == nil end) == 1
  end

  test "an eight punch day renders nine slots, eight filled plus one blank" do
    list =
      for {h, i} <- Enum.with_index(~w(07 08 09 10 11 12 13 14)) do
        entry("2026-05-05T#{h}:00:00+08:00", "id#{i}")
      end

    slots = Helpers.punch_slots(list, @company)
    assert length(slots) == 9
    assert Enum.count(slots, fn {time, _, _, _, _, _} -> time != nil end) == 8
  end

  test "blank slots carry a _new_ id so typing into one creates a punch" do
    slots = Helpers.punch_slots([entry("2026-05-05T07:00:00+08:00", "a")], @company)

    blanks = Enum.filter(slots, fn {time, _, _, _, _, _} -> time == nil end)
    assert length(blanks) == 5
    assert Enum.all?(blanks, fn {_, id, _, _, _, _} -> String.starts_with?(id, "_new_") end)
  end

  test "punches come back in time order regardless of input order" do
    list = [
      entry("2026-05-05T17:00:00+08:00", "late"),
      entry("2026-05-05T07:00:00+08:00", "early")
    ]

    assert [{_, "early", _, _, _, _}, {_, "late", _, _, _, _} | _] =
             Helpers.punch_slots(list, @company)
  end

  test "an empty day still renders six blank slots" do
    slots = Helpers.punch_slots(nil, @company)
    assert length(slots) == 6
    assert Enum.all?(slots, fn {time, _, _, _, _, _} -> time == nil end)
  end

  test "make_timeattend_list is gone" do
    refute function_exported?(FullCircleWeb.Helpers, :make_timeattend_list, 2)
  end

  test "nil times in the list are skipped so an edited row can rebuild" do
    list = [
      entry("2026-05-05T07:00:00+08:00", "a"),
      [nil, "_new_x", "normal", nil, "", ""]
    ]

    slots = Helpers.punch_slots(list, @company)
    assert Enum.count(slots, fn {time, _, _, _, _, _} -> time != nil end) == 1
    assert length(slots) == 6
  end

  test "a typed time on a night row lands in that instance, not the next one" do
    night = %FullCircle.HR.WorkShift{
      start_time: ~T[17:00:00],
      normal_hour: Decimal.new("9"),
      max_hour: Decimal.new("12")
    }

    # Instance anchored 5 May, paid on 6 May. 17:00 belongs to the 5th.
    assert ~D[2026-05-05] =
             FullCircleWeb.TimeAttendLive.PunchTimeComponent.slot_date(
               "17:00",
               ~D[2026-05-05],
               night
             )

    # 02:00 is before the 11:00 cutover, so it is the morning after.
    assert ~D[2026-05-06] =
             FullCircleWeb.TimeAttendLive.PunchTimeComponent.slot_date(
               "02:00",
               ~D[2026-05-05],
               night
             )
  end
end
