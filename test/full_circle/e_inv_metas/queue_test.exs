defmodule FullCircle.EInvMetas.QueueTest do
  use FullCircle.DataCase, async: true

  alias FullCircle.EInvMetas.Queue

  describe "stage_of/1 purchase" do
    test "needs_bill when neither bill nor payment" do
      assert Queue.stage_of(%{flow: :purchase, pur_invoice_id: nil, payment_id: nil}) ==
               :needs_bill
    end

    test "billed when pur invoice only" do
      assert Queue.stage_of(%{
               flow: :purchase,
               pur_invoice_id: Ecto.UUID.generate(),
               payment_id: nil
             }) == :billed
    end

    test "paid when payment present" do
      assert Queue.stage_of(%{
               flow: :purchase,
               pur_invoice_id: nil,
               payment_id: Ecto.UUID.generate()
             }) == :paid
    end
  end

  describe "stage_of/1 sales (self-billed)" do
    test "needs_invoice when neither invoice nor receipt" do
      assert Queue.stage_of(%{flow: :sales, invoice_id: nil, receipt_id: nil}) == :needs_invoice
    end

    test "invoiced when sales invoice only" do
      assert Queue.stage_of(%{
               flow: :sales,
               invoice_id: Ecto.UUID.generate(),
               receipt_id: nil
             }) == :invoiced
    end

    test "receipted when receipt present" do
      assert Queue.stage_of(%{
               flow: :sales,
               invoice_id: Ecto.UUID.generate(),
               receipt_id: Ecto.UUID.generate()
             }) == :receipted
    end
  end
end
