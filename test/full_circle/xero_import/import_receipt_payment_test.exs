defmodule FullCircle.XeroImport.ImportReceiptPaymentTest do
  use FullCircle.DataCase

  alias FullCircle.{Billing, ReceiveFund, BillPay, Accounting, Repo}
  alias FullCircle.Accounting.{Transaction, TaxCode}

  import FullCircle.BillingFixtures
  import FullCircle.ReceiveFundFixtures
  import FullCircle.BillPayFixtures

  setup do
    billing_setup()
  end

  test "keeps the supplied receipt number, matches AR, and does not bump gapless", %{
    admin: admin,
    company: company
  } do
    contact = contact_fixture(company, admin)
    good = good_fixture(company, admin)
    sales = Accounting.get_account_by_name("General Sales", company, admin)
    funds = funds_account_fixture(company, admin)

    no_stax =
      Repo.one!(from tc in TaxCode, where: tc.company_id == ^company.id and tc.code == "NoSTax")

    inv_before = gapless_current(company.id, "Invoice")
    rc_before = gapless_current(company.id, "Receipt")

    inv_attrs = invoice_attrs(contact, good, sales, no_stax) |> Map.put("invoice_no", "INV-000123")
    assert {:ok, _} = Billing.import_invoice(inv_attrs, company, admin)

    ar_txn =
      Repo.one!(
        from t in Transaction,
          join: a in FullCircle.Accounting.Account,
          on: a.id == t.account_id,
          where:
            t.doc_no == "INV-000123" and t.doc_type == "Invoice" and
              a.name == "Account Receivables"
      )

    receipt_attrs = %{
      "receipt_no" => "RC-XERO-1",
      "receipt_date" => Date.to_iso8601(Date.utc_today()),
      "contact_id" => contact.id,
      "contact_name" => contact.name,
      "funds_account_id" => funds.id,
      "funds_account_name" => funds.name,
      "funds_amount" => "50.00",
      "receipt_details" => %{},
      "transaction_matchers" => %{
        "0" => %{
          "transaction_id" => ar_txn.id,
          "match_amount" => "-50.00",
          "doc_type" => "Receipt",
          "doc_date" => Date.to_iso8601(Date.utc_today()),
          "_persistent_id" => "1"
        }
      }
    }

    assert {:ok, %{create_receipt: rc}} = ReceiveFund.import_receipt(receipt_attrs, company, admin)
    assert rc.receipt_no == "RC-XERO-1"

    loaded = ReceiveFund.get_receipt!(rc.id, company, admin)
    assert length(loaded.transaction_matchers) == 1
    assert Decimal.eq?(hd(loaded.transaction_matchers).match_amount, Decimal.new("-50.00"))

    txns =
      Repo.all(from t in Transaction, where: t.doc_type == "Receipt" and t.doc_no == "RC-XERO-1")

    assert txns != []

    assert gapless_current(company.id, "Invoice") == inv_before
    assert gapless_current(company.id, "Receipt") == rc_before
  end

  test "keeps the supplied payment number, matches AP, and does not bump gapless", %{
    admin: admin,
    company: company
  } do
    contact = contact_fixture(company, admin)
    good = good_fixture(company, admin)
    purchases = Accounting.get_account_by_name("General Purchases", company, admin)
    funds = pay_funds_account_fixture(company, admin)

    no_ptax =
      Repo.one!(from tc in TaxCode, where: tc.company_id == ^company.id and tc.code == "NoPTax")

    bill_before = gapless_current(company.id, "PurInvoice")
    pv_before = gapless_current(company.id, "Payment")

    bill_attrs =
      pur_invoice_attrs(contact, good, purchases, no_ptax) |> Map.put("pur_invoice_no", "BILL-10")

    assert {:ok, _} = Billing.import_pur_invoice(bill_attrs, company, admin)

    ap_txn =
      Repo.one!(
        from t in Transaction,
          join: a in FullCircle.Accounting.Account,
          on: a.id == t.account_id,
          where:
            t.doc_no == "BILL-10" and t.doc_type == "PurInvoice" and a.name == "Account Payables"
      )

    payment_attrs = %{
      "payment_no" => "PV-XERO-1",
      "payment_date" => Date.to_iso8601(Date.utc_today()),
      "contact_id" => contact.id,
      "contact_name" => contact.name,
      "funds_account_id" => funds.id,
      "funds_account_name" => funds.name,
      "funds_amount" => "50.00",
      "payment_details" => %{},
      "transaction_matchers" => %{
        "0" => %{
          "transaction_id" => ap_txn.id,
          "match_amount" => "50.00",
          "doc_type" => "Payment",
          "doc_date" => Date.to_iso8601(Date.utc_today()),
          "_persistent_id" => "1"
        }
      }
    }

    assert {:ok, %{create_payment: pv}} = BillPay.import_payment(payment_attrs, company, admin)
    assert pv.payment_no == "PV-XERO-1"

    loaded = BillPay.get_payment!(pv.id, company, admin)
    assert length(loaded.transaction_matchers) == 1
    assert Decimal.eq?(hd(loaded.transaction_matchers).match_amount, Decimal.new("50.00"))

    txns =
      Repo.all(from t in Transaction, where: t.doc_type == "Payment" and t.doc_no == "PV-XERO-1")

    assert txns != []

    assert gapless_current(company.id, "PurInvoice") == bill_before
    assert gapless_current(company.id, "Payment") == pv_before
  end

  defp gapless_current(company_id, doc_type) do
    Repo.one!(
      from g in FullCircle.Sys.GaplessDocId,
        where: g.company_id == ^company_id and g.doc_type == ^doc_type,
        select: g.current
    )
  end
end
