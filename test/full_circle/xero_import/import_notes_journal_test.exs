defmodule FullCircle.XeroImport.ImportNotesJournalTest do
  use FullCircle.DataCase

  alias FullCircle.{DebCre, JournalEntry, Accounting, Repo}
  alias FullCircle.Accounting.{Transaction, TaxCode}

  import FullCircle.BillingFixtures
  import FullCircle.DebCreFixtures

  setup do
    billing_setup()
  end

  test "keeps the supplied credit note number and does not bump gapless", %{
    admin: admin,
    company: company
  } do
    contact = contact_fixture(company, admin)
    sales_acct = Accounting.get_account_by_name("General Sales", company, admin)

    no_stax =
      Repo.one!(from tc in TaxCode, where: tc.company_id == ^company.id and tc.code == "NoSTax")

    cn_before = gapless_current(company.id, "CreditNote")
    dn_before = gapless_current(company.id, "DebitNote")

    attrs = credit_note_attrs(contact, sales_acct, no_stax) |> Map.put("note_no", "CN-9")

    assert {:ok, %{create_credit_note: cn}} = DebCre.import_credit_note(attrs, company, admin)
    assert cn.note_no == "CN-9"

    txns =
      Repo.all(from t in Transaction, where: t.doc_type == "CreditNote" and t.doc_no == "CN-9")

    assert txns != []

    assert gapless_current(company.id, "CreditNote") == cn_before
    assert gapless_current(company.id, "DebitNote") == dn_before
  end

  test "keeps the supplied debit note number and does not bump gapless", %{
    admin: admin,
    company: company
  } do
    contact = contact_fixture(company, admin)
    pur_acct = Accounting.get_account_by_name("General Purchases", company, admin)

    no_ptax =
      Repo.one!(from tc in TaxCode, where: tc.company_id == ^company.id and tc.code == "NoPTax")

    cn_before = gapless_current(company.id, "CreditNote")
    dn_before = gapless_current(company.id, "DebitNote")

    attrs = debit_note_attrs(contact, pur_acct, no_ptax) |> Map.put("note_no", "DN-9")

    assert {:ok, %{create_debit_note: dn}} = DebCre.import_debit_note(attrs, company, admin)
    assert dn.note_no == "DN-9"

    txns =
      Repo.all(from t in Transaction, where: t.doc_type == "DebitNote" and t.doc_no == "DN-9")

    assert txns != []

    assert gapless_current(company.id, "CreditNote") == cn_before
    assert gapless_current(company.id, "DebitNote") == dn_before
  end

  test "keeps the supplied journal number, balances, and does not bump gapless", %{
    admin: admin,
    company: company
  } do
    js_before = gapless_current(company.id, "Journal")

    attrs =
      journal_attrs_dated(company, admin, Date.utc_today())
      |> Map.put("journal_no", "JS-XERO-1")

    assert {:ok, %{create_journal: js}} = JournalEntry.import_journal(attrs, company, admin)
    assert js.journal_no == "JS-XERO-1"
    assert Decimal.eq?(js.journal_balance, Decimal.new("0"))

    txns =
      Repo.all(from t in Transaction, where: t.doc_type == "Journal" and t.doc_no == "JS-XERO-1")

    assert txns != []
    assert Decimal.eq?(Enum.reduce(txns, Decimal.new(0), &Decimal.add(&1.amount, &2)), Decimal.new("0"))

    assert gapless_current(company.id, "Journal") == js_before
  end

  defp journal_attrs_dated(company, user, date) do
    debit = Accounting.get_account_by_name("General Purchases", company, user)
    credit = Accounting.get_account_by_name("General Sales", company, user)

    %{
      "journal_date" => Date.to_string(date),
      "transactions" => %{
        "0" => %{
          "account_id" => debit.id,
          "account_name" => debit.name,
          "particulars" => "Test journal debit",
          "amount" => "100.00",
          "_persistent_id" => "0"
        },
        "1" => %{
          "account_id" => credit.id,
          "account_name" => credit.name,
          "particulars" => "Test journal credit",
          "amount" => "-100.00",
          "_persistent_id" => "1"
        }
      }
    }
  end

  defp gapless_current(company_id, doc_type) do
    Repo.one!(
      from g in FullCircle.Sys.GaplessDocId,
        where: g.company_id == ^company_id and g.doc_type == ^doc_type,
        select: g.current
    )
  end
end
