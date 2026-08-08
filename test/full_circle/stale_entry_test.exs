defmodule FullCircle.StaleEntryTest do
  @moduledoc """
  A record loaded into an open form can be deleted or changed by another user
  before that form is saved. Ecto raises `Ecto.StaleEntryError` when the UPDATE
  touches zero rows — either because the row is gone, or because
  `optimistic_lock/2` no longer matches the lock_version the form was loaded
  with. Every update path must turn that into `{:error, :stale}` rather than
  letting the exception escape and crash the LiveView.
  """
  use FullCircle.DataCase

  alias FullCircle.{Billing, BillPay, Cheque, DebCre, JournalEntry, ReceiveFund, StdInterface}
  alias FullCircle.Accounting.{Contact, Journal}
  alias FullCircle.Billing.{Invoice, PurInvoice}
  alias FullCircle.BillPay.Payment
  alias FullCircle.Cheque.{Deposit, ReturnCheque}
  alias FullCircle.DebCre.{CreditNote, DebitNote}
  alias FullCircle.ReceiveFund.Receipt
  alias FullCircle.Product.Good
  alias FullCircle.EInvMetas

  import FullCircle.BillingFixtures
  import FullCircle.BillPayFixtures
  import FullCircle.ChequeFixtures
  import FullCircle.DebCreFixtures
  import FullCircle.ReceiveFundFixtures

  setup do
    %{admin: admin, company: company} = billing_setup()
    %{admin: admin, company: company}
  end

  defp delete_row!(schema, id) do
    {1, _} = Repo.delete_all(from(r in schema, where: r.id == ^id))
    :ok
  end

  describe "StdInterface.update/7" do
    test "returns {:error, :stale} when the record was deleted by someone else", %{
      admin: admin,
      company: company
    } do
      contact = contact_fixture(company, admin)
      :ok = delete_row!(Contact, contact.id)

      assert {:error, :stale} =
               StdInterface.update(
                 Contact,
                 "contact",
                 contact,
                 %{"name" => "Renamed By Stale Form"},
                 company,
                 admin
               )
    end
  end

  describe "Billing.update_invoice/5" do
    test "returns {:error, :stale} when the invoice was deleted by someone else", %{
      admin: admin,
      company: company
    } do
      invoice = invoice_fixture(company, admin)
      loaded = Billing.get_invoice!(invoice.id, company, admin)
      :ok = delete_row!(Invoice, loaded.id)

      attrs = %{
        "e_inv_internal_id" => loaded.e_inv_internal_id,
        "invoice_no" => loaded.invoice_no,
        "descriptions" => "edited in a stale form"
      }

      assert {:error, :stale} = Billing.update_invoice(loaded, attrs, company, admin)
    end
  end

  describe "Billing.update_pur_invoice/5" do
    test "returns {:error, :stale} when the purchase invoice was deleted by someone else", %{
      admin: admin,
      company: company
    } do
      pur_invoice = pur_invoice_fixture(company, admin)
      loaded = Billing.get_pur_invoice!(pur_invoice.id, company, admin)
      :ok = delete_row!(PurInvoice, loaded.id)

      attrs = %{
        "pur_invoice_no" => loaded.pur_invoice_no,
        "descriptions" => "edited in a stale form"
      }

      assert {:error, :stale} = Billing.update_pur_invoice(loaded, attrs, company, admin)
    end
  end

  describe "ReceiveFund.update_receipt/4" do
    test "returns {:error, :stale} when the receipt was deleted by someone else", %{
      admin: admin,
      company: company
    } do
      receipt = receipt_fixture(company, admin)
      loaded = ReceiveFund.get_receipt!(receipt.id, company, admin)
      :ok = delete_row!(Receipt, loaded.id)

      attrs = %{
        "receipt_no" => loaded.receipt_no,
        "descriptions" => "edited in a stale form"
      }

      assert {:error, :stale} = ReceiveFund.update_receipt(loaded, attrs, company, admin)
    end
  end

  describe "BillPay.update_payment/4" do
    test "returns {:error, :stale} when the payment was deleted by someone else", %{
      admin: admin,
      company: company
    } do
      payment = payment_fixture(company, admin)
      loaded = BillPay.get_payment!(payment.id, company, admin)
      :ok = delete_row!(Payment, loaded.id)

      attrs = %{
        "payment_no" => loaded.payment_no,
        "descriptions" => "edited in a stale form"
      }

      assert {:error, :stale} = BillPay.update_payment(loaded, attrs, company, admin)
    end
  end

  describe "DebCre.update_credit_note/4" do
    test "returns {:error, :stale} when the credit note was deleted by someone else", %{
      admin: admin,
      company: company
    } do
      credit_note = credit_note_fixture(company, admin)
      loaded = DebCre.get_credit_note!(credit_note.id, company, admin)
      :ok = delete_row!(CreditNote, loaded.id)

      attrs = %{
        "note_no" => loaded.note_no,
        "note_date" => loaded.note_date |> Date.add(1) |> Date.to_iso8601()
      }

      assert {:error, :stale} = DebCre.update_credit_note(loaded, attrs, company, admin)
    end
  end

  describe "DebCre.update_debit_note/4" do
    test "returns {:error, :stale} when the debit note was deleted by someone else", %{
      admin: admin,
      company: company
    } do
      debit_note = debit_note_fixture(company, admin)
      loaded = DebCre.get_debit_note!(debit_note.id, company, admin)
      :ok = delete_row!(DebitNote, loaded.id)

      attrs = %{
        "note_no" => loaded.note_no,
        "note_date" => loaded.note_date |> Date.add(1) |> Date.to_iso8601()
      }

      assert {:error, :stale} = DebCre.update_debit_note(loaded, attrs, company, admin)
    end
  end

  describe "Cheque.update_deposit/4" do
    test "returns {:error, :stale} when the deposit was deleted by someone else", %{
      admin: admin,
      company: company
    } do
      deposit = deposit_fixture(company, admin)
      loaded = Cheque.get_deposit!(deposit.id, company, admin)
      :ok = delete_row!(Deposit, loaded.id)

      attrs = %{
        "deposit_no" => loaded.deposit_no,
        "deposit_date" => loaded.deposit_date |> Date.add(1) |> Date.to_iso8601()
      }

      assert {:error, :stale} = Cheque.update_deposit(loaded, attrs, company, admin)
    end
  end

  describe "Cheque.update_return_cheque/4" do
    test "returns {:error, :stale} when the return cheque was deleted by someone else", %{
      admin: admin,
      company: company
    } do
      return_cheque = return_cheque_fixture(company, admin)
      loaded = Cheque.get_return_cheque!(return_cheque.id, company, admin)
      :ok = delete_row!(ReturnCheque, loaded.id)

      attrs = %{
        "return_no" => loaded.return_no,
        "return_reason" => "edited in a stale form"
      }

      assert {:error, :stale} = Cheque.update_return_cheque(loaded, attrs, company, admin)
    end
  end

  describe "JournalEntry.update_journal/4" do
    test "returns {:error, :stale} when the journal was deleted by someone else", %{
      admin: admin,
      company: company
    } do
      journal = journal_fixture(company, admin)
      loaded = JournalEntry.get_journal!(journal.id, company, admin)
      :ok = delete_row!(Journal, loaded.id)

      attrs = %{
        "journal_no" => loaded.journal_no,
        "journal_date" => Date.to_iso8601(loaded.journal_date),
        "transactions" => journal_txn_attrs(company, admin)
      }

      assert {:error, :stale} = JournalEntry.update_journal(loaded, attrs, company, admin)
    end
  end

  # Two users load the same record, both save. The first write wins; the second
  # must be refused rather than silently overwriting it.
  describe "concurrent edit (optimistic lock)" do
    test "second save of a concurrently-changed contact is refused", %{
      admin: admin,
      company: company
    } do
      contact = contact_fixture(company, admin)
      first = StdInterface.get!(Contact, contact.id)
      second = StdInterface.get!(Contact, contact.id)

      assert {:ok, _} =
               StdInterface.update(Contact, "contact", first, %{"city" => "Ipoh"}, company, admin)

      assert {:error, :stale} =
               StdInterface.update(
                 Contact,
                 "contact",
                 second,
                 %{"city" => "Penang"},
                 company,
                 admin
               )
    end

    test "second save of a concurrently-changed good is refused", %{
      admin: admin,
      company: company
    } do
      good = good_fixture(company, admin)
      first = FullCircle.Product.get_good!(good.id, company, admin)
      second = FullCircle.Product.get_good!(good.id, company, admin)

      assert {:ok, _} =
               StdInterface.update(
                 Good,
                 "good",
                 first,
                 %{"descriptions" => "first"},
                 company,
                 admin
               )

      assert {:error, :stale} =
               StdInterface.update(
                 Good,
                 "good",
                 second,
                 %{"descriptions" => "second"},
                 company,
                 admin
               )
    end

    test "second save of a concurrently-changed invoice is refused", %{
      admin: admin,
      company: company
    } do
      invoice = invoice_fixture(company, admin)
      first = Billing.get_invoice!(invoice.id, company, admin)
      second = Billing.get_invoice!(invoice.id, company, admin)

      base = %{"e_inv_internal_id" => first.e_inv_internal_id, "invoice_no" => first.invoice_no}

      assert {:ok, _} =
               Billing.update_invoice(
                 first,
                 Map.put(base, "descriptions", "first writer"),
                 company,
                 admin
               )

      assert {:error, :stale} =
               Billing.update_invoice(
                 second,
                 Map.put(base, "descriptions", "second writer"),
                 company,
                 admin
               )
    end

    test "second save of a concurrently-changed purchase invoice is refused", %{
      admin: admin,
      company: company
    } do
      pur_invoice = pur_invoice_fixture(company, admin)
      first = Billing.get_pur_invoice!(pur_invoice.id, company, admin)
      second = Billing.get_pur_invoice!(pur_invoice.id, company, admin)

      base = %{"pur_invoice_no" => first.pur_invoice_no}

      assert {:ok, _} =
               Billing.update_pur_invoice(
                 first,
                 Map.put(base, "descriptions", "first writer"),
                 company,
                 admin
               )

      assert {:error, :stale} =
               Billing.update_pur_invoice(
                 second,
                 Map.put(base, "descriptions", "second writer"),
                 company,
                 admin
               )
    end

    test "second save of a concurrently-changed receipt is refused", %{
      admin: admin,
      company: company
    } do
      receipt = receipt_fixture(company, admin)
      first = ReceiveFund.get_receipt!(receipt.id, company, admin)
      second = ReceiveFund.get_receipt!(receipt.id, company, admin)

      base = %{"receipt_no" => first.receipt_no}

      assert {:ok, _} =
               ReceiveFund.update_receipt(
                 first,
                 Map.put(base, "descriptions", "first writer"),
                 company,
                 admin
               )

      assert {:error, :stale} =
               ReceiveFund.update_receipt(
                 second,
                 Map.put(base, "descriptions", "second writer"),
                 company,
                 admin
               )
    end

    test "second save of a concurrently-changed payment is refused", %{
      admin: admin,
      company: company
    } do
      payment = payment_fixture(company, admin)
      first = BillPay.get_payment!(payment.id, company, admin)
      second = BillPay.get_payment!(payment.id, company, admin)

      base = %{"payment_no" => first.payment_no}

      assert {:ok, _} =
               BillPay.update_payment(
                 first,
                 Map.put(base, "descriptions", "first writer"),
                 company,
                 admin
               )

      assert {:error, :stale} =
               BillPay.update_payment(
                 second,
                 Map.put(base, "descriptions", "second writer"),
                 company,
                 admin
               )
    end

    test "second save of a concurrently-changed credit note is refused", %{
      admin: admin,
      company: company
    } do
      credit_note = credit_note_fixture(company, admin)
      first = DebCre.get_credit_note!(credit_note.id, company, admin)
      second = DebCre.get_credit_note!(credit_note.id, company, admin)

      base = %{"note_no" => first.note_no}

      assert {:ok, _} =
               DebCre.update_credit_note(
                 first,
                 Map.put(base, "note_date", first.note_date |> Date.add(1) |> Date.to_iso8601()),
                 company,
                 admin
               )

      assert {:error, :stale} =
               DebCre.update_credit_note(
                 second,
                 Map.put(base, "note_date", second.note_date |> Date.add(2) |> Date.to_iso8601()),
                 company,
                 admin
               )
    end

    test "second save of a concurrently-changed debit note is refused", %{
      admin: admin,
      company: company
    } do
      debit_note = debit_note_fixture(company, admin)
      first = DebCre.get_debit_note!(debit_note.id, company, admin)
      second = DebCre.get_debit_note!(debit_note.id, company, admin)

      base = %{"note_no" => first.note_no}

      assert {:ok, _} =
               DebCre.update_debit_note(
                 first,
                 Map.put(base, "note_date", first.note_date |> Date.add(1) |> Date.to_iso8601()),
                 company,
                 admin
               )

      assert {:error, :stale} =
               DebCre.update_debit_note(
                 second,
                 Map.put(base, "note_date", second.note_date |> Date.add(2) |> Date.to_iso8601()),
                 company,
                 admin
               )
    end

    test "second save of a concurrently-changed deposit is refused", %{
      admin: admin,
      company: company
    } do
      deposit = deposit_fixture(company, admin)
      first = Cheque.get_deposit!(deposit.id, company, admin)
      second = Cheque.get_deposit!(deposit.id, company, admin)

      base = %{"deposit_no" => first.deposit_no}

      assert {:ok, _} =
               Cheque.update_deposit(
                 first,
                 Map.put(
                   base,
                   "deposit_date",
                   first.deposit_date |> Date.add(1) |> Date.to_iso8601()
                 ),
                 company,
                 admin
               )

      assert {:error, :stale} =
               Cheque.update_deposit(
                 second,
                 Map.put(
                   base,
                   "deposit_date",
                   second.deposit_date |> Date.add(2) |> Date.to_iso8601()
                 ),
                 company,
                 admin
               )
    end

    test "second save of a concurrently-changed return cheque is refused", %{
      admin: admin,
      company: company
    } do
      return_cheque = return_cheque_fixture(company, admin)
      first = Cheque.get_return_cheque!(return_cheque.id, company, admin)
      second = Cheque.get_return_cheque!(return_cheque.id, company, admin)

      base = %{"return_no" => first.return_no}

      assert {:ok, _} =
               Cheque.update_return_cheque(
                 first,
                 Map.put(base, "return_reason", "first writer"),
                 company,
                 admin
               )

      assert {:error, :stale} =
               Cheque.update_return_cheque(
                 second,
                 Map.put(base, "return_reason", "second writer"),
                 company,
                 admin
               )
    end

    test "second save of a concurrently-changed journal is refused", %{
      admin: admin,
      company: company
    } do
      journal = journal_fixture(company, admin)
      first = JournalEntry.get_journal!(journal.id, company, admin)
      second = JournalEntry.get_journal!(journal.id, company, admin)

      base = %{
        "journal_no" => first.journal_no,
        "transactions" => journal_txn_attrs(company, admin)
      }

      assert {:ok, _} =
               JournalEntry.update_journal(
                 first,
                 Map.put(
                   base,
                   "journal_date",
                   first.journal_date |> Date.add(1) |> Date.to_iso8601()
                 ),
                 company,
                 admin
               )

      assert {:error, :stale} =
               JournalEntry.update_journal(
                 second,
                 Map.put(
                   base,
                   "journal_date",
                   second.journal_date |> Date.add(2) |> Date.to_iso8601()
                 ),
                 company,
                 admin
               )
    end
  end

  # Machine writes go through `update_all`, which bypasses `optimistic_lock`
  # entirely unless they bump the counter themselves. Without this, an LHDN
  # match or a learnt contact identifier is silently overwritten by whoever had
  # the record open at the time.
  describe "update_all writers bump the lock" do
    test "an LHDN e-invoice match refuses a form opened before it", %{
      admin: admin,
      company: company
    } do
      invoice = invoice_fixture(company, admin)
      open_form = Billing.get_invoice!(invoice.id, company, admin)

      assert {:ok, _} =
               EInvMetas.match(
                 %{"uuid" => "UUID-MATCH-1", "internalId" => open_form.invoice_no},
                 %{"doc_type" => "Invoice", "doc_id" => invoice.id},
                 company,
                 admin
               )

      assert {:error, :stale} =
               Billing.update_invoice(
                 open_form,
                 %{
                   "e_inv_internal_id" => open_form.e_inv_internal_id,
                   "invoice_no" => open_form.invoice_no,
                   "descriptions" => "saved over the LHDN match"
                 },
                 company,
                 admin
               )
    end

    test "an LHDN e-invoice unmatch refuses a form opened before it", %{
      admin: admin,
      company: company
    } do
      invoice = invoice_fixture(company, admin)
      open_form = Billing.get_invoice!(invoice.id, company, admin)

      assert {:ok, _} =
               EInvMetas.unmatch(
                 %{"doc_type" => "Invoice", "doc_id" => invoice.id},
                 company,
                 admin
               )

      assert {:error, :stale} =
               Billing.update_invoice(
                 open_form,
                 %{
                   "e_inv_internal_id" => open_form.e_inv_internal_id,
                   "invoice_no" => open_form.invoice_no,
                   "descriptions" => "saved over the LHDN unmatch"
                 },
                 company,
                 admin
               )
    end

    test "a learnt contact identifier refuses a form opened before it", %{
      admin: admin,
      company: company
    } do
      contact = contact_fixture(company, admin, %{"tax_id" => "", "reg_no" => ""})
      open_form = StdInterface.get!(Contact, contact.id)

      FullCircle.Accounting.learn_contact_identifiers(
        contact.id,
        "IG123456789",
        "198901001548",
        company,
        admin
      )

      assert {:error, :stale} =
               StdInterface.update(
                 Contact,
                 "contact",
                 open_form,
                 %{"city" => "saved over the learnt identifiers"},
                 company,
                 admin
               )
    end
  end

  defp journal_txn_attrs(company, user) do
    sales = FullCircle.Accounting.get_account_by_name("General Sales", company, user)
    ar = FullCircle.Accounting.get_account_by_name("Account Receivables", company, user)

    %{
      "0" => %{
        "particulars" => "stale test debit",
        "amount" => "100.00",
        "account_name" => ar.name,
        "account_id" => ar.id
      },
      "1" => %{
        "particulars" => "stale test credit",
        "amount" => "-100.00",
        "account_name" => sales.name,
        "account_id" => sales.id
      }
    }
  end

  defp journal_fixture(company, user) do
    attrs = %{
      "journal_date" => Date.to_iso8601(Date.utc_today()),
      "transactions" => journal_txn_attrs(company, user)
    }

    {:ok, %{create_journal: journal}} = JournalEntry.create_journal(attrs, company, user)
    journal
  end
end
