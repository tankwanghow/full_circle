defmodule FullCircle.ShiftInstanceTest do
  use ExUnit.Case, async: true

  alias FullCircle.HR.{ShiftInstance, WorkShift, TimeAttend}

  @tz "Asia/Kuala_Lumpur"

  defp night,
    do: %WorkShift{
      id: "ws-night",
      name: "Night",
      start_time: ~T[17:00:00],
      normal_hour: Decimal.new("9"),
      max_hour: Decimal.new("12")
    }

  defp general,
    do: %WorkShift{
      id: "ws-gen",
      name: "General",
      start_time: ~T[08:00:00],
      normal_hour: Decimal.new("9"),
      max_hour: Decimal.new("12"),
      is_default: true
    }

  defp p(iso),
    do: %TimeAttend{
      employee_id: "emp-1",
      work_shift_date: ~D[2026-05-05],
      punch_time: Timex.parse!(iso, "{RFC3339}")
    }

  describe "build/3 hours" do
    test "a night shift drifting early in and late out is paid in full" do
      punches = [
        p("2026-05-05T16:45:00+08:00"),
        p("2026-05-05T20:00:00+08:00"),
        p("2026-05-05T20:30:00+08:00"),
        p("2026-05-06T02:20:00+08:00")
      ]

      inst = ShiftInstance.build(punches, night(), @tz)

      assert_in_delta inst.worked, 9.083, 0.001
      assert is_nil(inst.anomaly)
      assert inst.pay_date == ~D[2026-05-06]
      assert inst.work_shift_date == ~D[2026-05-05]
    end

    test "a General day pays the same as calendar day grouping does today" do
      punches = [
        p("2026-05-05T07:00:00+08:00"),
        p("2026-05-05T12:00:00+08:00"),
        p("2026-05-05T13:00:00+08:00"),
        p("2026-05-05T17:00:00+08:00")
      ]

      inst = ShiftInstance.build(punches, general(), @tz)

      assert_in_delta inst.worked, 9.0, 0.001
      assert inst.pay_date == ~D[2026-05-05]
      assert is_nil(inst.anomaly)
    end

    test "four pairs are all paid, with no ceiling at three" do
      punches =
        Enum.map(
          [
            "2026-05-05T08:00:00+08:00",
            "2026-05-05T10:00:00+08:00",
            "2026-05-05T10:30:00+08:00",
            "2026-05-05T12:30:00+08:00",
            "2026-05-05T13:30:00+08:00",
            "2026-05-05T15:30:00+08:00",
            "2026-05-05T16:00:00+08:00",
            "2026-05-05T18:00:00+08:00"
          ],
          &p/1
        )

      inst = ShiftInstance.build(punches, general(), @tz)

      assert length(inst.punches) == 8
      assert_in_delta inst.worked, 8.0, 0.001
      assert is_nil(inst.anomaly)
    end

    test "punches arriving out of order are sorted before pairing" do
      punches = [
        p("2026-05-05T17:00:00+08:00"),
        p("2026-05-05T08:00:00+08:00")
      ]

      assert_in_delta ShiftInstance.build(punches, general(), @tz).worked, 9.0, 0.001
    end

    test "a genuine zero hour day is 0.0, not nil" do
      punches = [
        p("2026-05-05T08:00:00+08:00"),
        p("2026-05-05T08:00:00+08:00")
      ]

      inst = ShiftInstance.build(punches, general(), @tz)
      assert inst.worked == 0.0
      assert is_nil(inst.anomaly)
    end
  end

  describe "build/3 anomalies" do
    test "an odd punch count is a missing punch, and hours are blank" do
      punches = [
        p("2026-05-05T08:00:00+08:00"),
        p("2026-05-05T12:00:00+08:00"),
        p("2026-05-05T13:00:00+08:00")
      ]

      inst = ShiftInstance.build(punches, general(), @tz)
      assert inst.anomaly == :missing_punch
      assert is_nil(inst.worked)
    end

    test "a single punch is a missing punch" do
      inst = ShiftInstance.build([p("2026-05-05T08:00:00+08:00")], general(), @tz)
      assert inst.anomaly == :missing_punch
      assert is_nil(inst.worked)
    end

    # Both punches are inside one General window (cutover 02:00), which is what
    # :too_long requires. Note that 08:00 on the 5th with 17:00 on the *6th* is
    # NOT this case - those are two instances of one punch each, two
    # :missing_punch days. Task 7 covers that; feeding both to build/3 here
    # would test an input the resolver cannot produce.
    test "a span beyond max_hour is too_long, and hours are blank" do
      punches = [
        p("2026-05-05T07:00:00+08:00"),
        p("2026-05-05T21:00:00+08:00")
      ]

      inst = ShiftInstance.build(punches, general(), @tz)
      assert inst.anomaly == :too_long
      assert is_nil(inst.worked)
      assert_in_delta inst.span_hours, 14.0, 0.001
    end

    test "a span exactly at max_hour is not an anomaly" do
      punches = [
        p("2026-05-05T08:00:00+08:00"),
        p("2026-05-05T20:00:00+08:00")
      ]

      assert is_nil(ShiftInstance.build(punches, general(), @tz).anomaly)
    end

    test "no punches means no instance" do
      assert is_nil(ShiftInstance.build([], general(), @tz))
    end
  end

  describe "punch_kind/1 and flag/1" do
    test "odd positions are IN, even are OUT" do
      assert ShiftInstance.punch_kind(1) == "IN"
      assert ShiftInstance.punch_kind(2) == "OUT"
      assert ShiftInstance.punch_kind(7) == "IN"
      assert ShiftInstance.punch_kind(8) == "OUT"
    end

    test "flags number the pair and do not stop at three" do
      assert ShiftInstance.flag(1) == "1_IN_1"
      assert ShiftInstance.flag(2) == "1_OUT_1"
      assert ShiftInstance.flag(5) == "3_IN_3"
      assert ShiftInstance.flag(6) == "3_OUT_3"
      assert ShiftInstance.flag(7) == "4_IN_4"
      assert ShiftInstance.flag(8) == "4_OUT_4"
    end
  end
end
