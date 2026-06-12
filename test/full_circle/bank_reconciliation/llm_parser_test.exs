defmodule FullCircle.BankReconciliation.LlmParserTest do
  use ExUnit.Case, async: true

  alias FullCircle.BankReconciliation.LlmParser

  describe "normalize_transaction/1" do
    test "accepts DD-MM-YYYY dates from bank statements" do
      assert %{
               statement_date: ~D[2026-05-01],
               description: "RPP INWARD",
               amount: amount
             } =
               LlmParser.normalize_transaction(%{
                 "statement_date" => "01-05-2026",
                 "description" => "RPP INWARD",
                 "cheque_no" => nil,
                 "amount" => 3390.00
               })

      assert Decimal.eq?(amount, Decimal.new("3390.00"))
    end

    test "accepts ISO dates" do
      assert %{statement_date: ~D[2026-05-01]} =
               LlmParser.normalize_transaction(%{
                 "statement_date" => "2026-05-01",
                 "description" => "test",
                 "amount" => 1
               })
    end
  end
end