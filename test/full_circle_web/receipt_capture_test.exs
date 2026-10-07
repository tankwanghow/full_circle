defmodule FullCircleWeb.ReceiptCaptureTest do
  use FullCircle.DataCase, async: true

  import FullCircle.BillingFixtures
  import FullCircle.BillPayFixtures
  import FullCircle.NotesFixtures
  import Ecto.Query

  alias FullCircle.{Accounting, BillPay, Repo}
  alias FullCircle.Notes.{Attachments, Note, Trays}
  alias FullCircleWeb.ReceiptCapture

  describe "merge_params/3" do
    @seed %{
      contact_name: "Kedai Ali",
      contact_id: "c-1",
      tax_id: "C1",
      reg_no: nil,
      payment_date: ~D[2026-10-03],
      funds_amount: Decimal.new("54.00"),
      descriptions: "Kedai Ali #A1",
      payment_details: [%{"descriptions" => "PVC", "quantity" => 4, "_persistent_id" => 0}]
    }

    test "fills blanks, keyed values win, zero counts as blank" do
      current = %{
        "payment_no" => "...new...",
        "descriptions" => "my words",
        "funds_amount" => "0",
        "payment_date" => ""
      }

      merged = ReceiptCapture.merge_params(current, @seed, :payment_details)

      assert merged["descriptions"] == "my words"
      assert merged["payment_no"] == "...new..."
      assert merged["payment_date"] == ~D[2026-10-03]
      assert Decimal.eq?(merged["funds_amount"], Decimal.new("54.00"))

      assert merged["payment_details"] == %{
               "0" => %{"descriptions" => "PVC", "quantity" => 4, "_persistent_id" => 0}
             }
    end

    test "a contact the clerk picked is kept whole — never half-merged" do
      current = %{"contact_name" => "Mine Sdn Bhd", "contact_id" => "", "tax_id" => ""}
      merged = ReceiptCapture.merge_params(current, @seed, :payment_details)
      assert merged["contact_name"] == "Mine Sdn Bhd"
      assert merged["contact_id"] == ""
      assert merged["tax_id"] == ""
    end

    test "keyed lines are kept; blank lines are replaced" do
      keyed = %{
        "payment_details" => %{
          "0" => %{"good_name" => "Glue", "quantity" => "1", "unit_price" => "4"}
        }
      }

      assert ReceiptCapture.merge_params(keyed, @seed, :payment_details)["payment_details"] ==
               keyed["payment_details"]

      blank = %{
        "payment_details" => %{
          "0" => %{"good_name" => "", "quantity" => "0", "unit_price" => "0"}
        }
      }

      assert %{"0" => %{"descriptions" => "PVC"}} =
               ReceiptCapture.merge_params(blank, @seed, :payment_details)["payment_details"]
    end
  end

  describe "attach_multi/5" do
    setup do
      %{admin: u, company: c} = billing_setup()
      contact = contact_fixture(c, u)
      good = good_fixture(c, u)
      pur_acct = Accounting.get_account_by_name("General Purchases", c, u)

      tc =
        Repo.one!(
          from t in FullCircle.Accounting.TaxCode,
            where: t.company_id == ^c.id and t.code == "NoPTax"
        )

      attrs =
        payment_attrs(contact, good, pur_acct, tc, pay_funds_account_fixture(c, u), tax_rate: "0")

      %{u: u, c: c, attrs: attrs}
    end

    test "a tray with files becomes a 🧾 Receipt note on the new payment", %{
      u: u,
      c: c,
      attrs: attrs
    } do
      tray = tray_fixture(c, u)

      {:ok, _} =
        Attachments.attach_to_tray(
          tray.id,
          %{path: real_jpeg_file(:rgb), file_name: "r.jpg"},
          c,
          u
        )

      {:ok, %{create_payment: pv}} =
        BillPay.create_payment(
          attrs,
          c,
          u,
          ReceiptCapture.attach_multi(tray.id, "Payment", :create_payment, c, u)
        )

      note =
        Repo.one!(
          from n in Note,
            where: n.subject_type == "Payment" and n.subject_id == ^pv.id,
            preload: :attachments
        )

      assert note.title == "🧾 Receipt"
      assert note.visibility == nil
      assert [%{file_name: "r.jpg"}] = note.attachments
      refute Trays.has_files?(tray.id, c, u)
    end

    test "an empty tray adds nothing", %{u: u, c: c, attrs: attrs} do
      {:ok, _} =
        BillPay.create_payment(
          attrs,
          c,
          u,
          ReceiptCapture.attach_multi(Ecto.UUID.generate(), "Payment", :create_payment, c, u)
        )

      assert Repo.aggregate(Note, :count) == 0
    end

    test "a user without :create_note: payment saves, receipt not attached", %{
      u: u,
      c: c,
      attrs: attrs
    } do
      guest = user_with_role(c, u, "guest")
      tray = tray_fixture(c, guest)

      {:ok, _} =
        Attachments.attach_to_tray(
          tray.id,
          %{path: real_jpeg_file(:rgb), file_name: "r.jpg"},
          c,
          guest
        )

      assert ReceiptCapture.attach_blocked?(tray.id, c, guest)

      assert ReceiptCapture.attach_multi(tray.id, "Payment", :create_payment, c, guest).(
               Ecto.Multi.new()
             ) == Ecto.Multi.new()
    end
  end
end
