defmodule FullCircle.EInvMetas.QueueTest do
  use FullCircle.DataCase, async: true

  alias FullCircle.EInvMetas.Queue

  describe "stage_of/1" do
    test "needs_bill when neither bill nor payment" do
      assert Queue.stage_of(%{pur_invoice_id: nil, payment_id: nil}) == :needs_bill
    end

    test "billed when pur invoice only" do
      assert Queue.stage_of(%{pur_invoice_id: Ecto.UUID.generate(), payment_id: nil}) == :billed
    end

    test "paid when payment present even without pur invoice" do
      assert Queue.stage_of(%{
               pur_invoice_id: nil,
               payment_id: Ecto.UUID.generate()
             }) == :paid
    end

    test "paid when both pur invoice and payment present" do
      assert Queue.stage_of(%{
               pur_invoice_id: Ecto.UUID.generate(),
               payment_id: Ecto.UUID.generate()
             }) == :paid
    end
  end
end
