defmodule FullCircle.BankReconciliation.AutoMatcherTest do
  use ExUnit.Case, async: true

  alias FullCircle.BankReconciliation.AutoMatcher

  describe "match/2" do
    test "pairs duplicate RM 34000 cheques by bank cheque number" do
      date = ~D[2026-04-09]
      amount = Decimal.new("34000")

      stmts =
        for {cheque, id} <- Enum.with_index(["319557", "319095", "319556"], 1) do
          %{
            id: "s#{id}",
            date: date,
            amount: amount,
            cheque_no: "0000024#{id}",
            description: "LOCAL CHQ DEP | #{cheque} PBB | - | 0000024#{id}"
          }
        end

      txns =
        for {cheque, id} <- Enum.with_index(["319557", "319095", "319556"], 1) do
          %{
            id: "t#{id}",
            date: date,
            amount: amount,
            doc_no: "DS-000611",
            particulars: "PBB #{cheque}"
          }
        end

      matches = AutoMatcher.match(stmts, txns)

      assert length(matches) == 3

      pairs =
        Map.new(matches, fn {[sid], [tid], _score} -> {sid, tid} end)

      assert pairs["s1"] == "t1"
      assert pairs["s2"] == "t2"
      assert pairs["s3"] == "t3"
    end

    test "rejects amount-only match when dates are far apart" do
      stmt = %{
        id: "s1",
        date: ~D[2026-04-29],
        amount: Decimal.new("-285179.02"),
        cheque_no: nil,
        description: "CLEARING CHQ | 2026042902180802519965048 | 00706230"
      }

      txn = %{
        id: "t1",
        date: ~D[2026-04-15],
        amount: Decimal.new("-285179.02"),
        doc_no: "PV-007469",
        particulars: "Payment to Tong Seh Industries Supply Sdn Bhd"
      }

      assert AutoMatcher.match([stmt], [txn]) == []
    end

    test "still matches same-day receive fund without cheque reference" do
      date = ~D[2026-04-06]

      stmt = %{
        id: "s1",
        date: date,
        amount: Decimal.new("35130.00"),
        cheque_no: "00000188",
        description: "LOCAL CHQ DEP | 000580 MBIS | - | 00000188"
      }

      txn = %{
        id: "t1",
        date: date,
        amount: Decimal.new("35130.00"),
        doc_no: "RC-007995",
        particulars: "Received from JNJ LGK SDN BHD"
      }

      assert [{["s1"], ["t1"], score}] = AutoMatcher.match([stmt], [txn])
      assert score == 40
    end

    test "prefers closest date when scores tie without cheque reference" do
      stmt = %{
        id: "s1",
        date: ~D[2026-04-10],
        amount: Decimal.new("1000"),
        cheque_no: nil,
        description: "RPP INWARD INST TRF"
      }

      txns = [
        %{
          id: "t_far",
          date: ~D[2026-04-01],
          amount: Decimal.new("1000"),
          doc_no: "RC-001",
          particulars: "Customer A"
        },
        %{
          id: "t_near",
          date: ~D[2026-04-09],
          amount: Decimal.new("1000"),
          doc_no: "RC-002",
          particulars: "Customer B"
        }
      ]

      assert AutoMatcher.match([stmt], txns) == [{["s1"], ["t_near"], 20}]
    end
  end

  describe "score/2" do
    test "gives reference bonus for bank cheque in particulars" do
      stmt = %{
        id: "s1",
        date: ~D[2026-04-13],
        amount: Decimal.new("1000"),
        cheque_no: "00000157",
        description: "LOCAL CHQ DEP | 221888 PIBB | - | 00000157"
      }

      txn = %{
        id: "t1",
        date: ~D[2026-04-13],
        amount: Decimal.new("1000"),
        doc_no: "DS-000612",
        particulars: "PBIB 221888"
      }

      assert AutoMatcher.score(stmt, txn) == 90
    end
  end
end