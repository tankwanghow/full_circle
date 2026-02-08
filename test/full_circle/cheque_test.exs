defmodule FullCircle.ChequeTest do
  use FullCircle.DataCase

  alias FullCircle.Cheque
  alias FullCircle.Accounting
  alias FullCircle.Accounting.Transaction

  import FullCircle.BillingFixtures
  import FullCircle.ChequeFixtures
  import FullCircle.ReceiveFundFixtures
  import FullCircle.UserAccountsFixtures

  setup do
    %{admin: admin, company: company} = billing_setup()
    %{admin: admin, company: company}
  end

  # --- AUTHORIZATION ---

  describe "cheque authorization" do
    test_authorise_to(
      :create_deposit,
      ["admin", "manager", "supervisor", "clerk", "cashier", "disable", "punch_camera"]
    )

    test_authorise_to(
      :update_deposit,
      ["admin", "manager", "supervisor", "clerk", "cashier", "disable", "punch_camera"]
    )

    test_authorise_to(
      :create_return_cheque,
      ["admin", "manager", "supervisor", "clerk", "disable", "punch_camera"]
    )

    test_authorise_to(
      :update_return_cheque,
      ["admin", "manager", "supervisor", "clerk", "disable", "punch_camera"]
    )
  end

  # --- DEPOSIT CREATE ---

  describe "create_deposit/3" do
    test "creates deposit with gapless doc number", %{admin: admin, company: company} do
      bank_acct = bank_account_fixture(company, admin)
      funds_from_acct = funds_account_fixture(company, admin)

      attrs = %{
        "deposit_date" => Date.to_string(Date.utc_today()),
        "bank_name" => bank_acct.name,
        "bank_id" => bank_acct.id,
        "funds_from_name" => funds_from_acct.name,
        "funds_from_id" => funds_from_acct.id,
        "funds_amount" => "100.00",
        "descriptions" => "Test deposit"
      }

      assert {:ok, %{create_deposit: deposit}} =
               Cheque.create_deposit(attrs, company, admin)

      assert deposit.deposit_no =~ ~r/^DS-\d{6}$/
      assert deposit.company_id == company.id
    end

    test "creates GL transactions: debit bank + credit source", %{
      admin: admin,
      company: company
    } do
      deposit = deposit_fixture(company, admin, funds_amount: "100.00")

      txns =
        Repo.all(
          from t in Transaction,
            where: t.doc_id == ^deposit.id and t.doc_type == "Deposit"
        )

      # funds_from debit + bank credit = 2
      assert length(txns) == 2

      positive = Enum.find(txns, fn t -> Decimal.positive?(t.amount) end)
      assert Decimal.eq?(positive.amount, Decimal.new("100.00"))

      negative = Enum.find(txns, fn t -> Decimal.negative?(t.amount) end)
      assert Decimal.eq?(negative.amount, Decimal.new("-100.00"))
    end

    test "returns :not_authorise for guest user", %{admin: admin, company: company} do
      guest = user_fixture()
      FullCircle.Sys.allow_user_to_access(company, guest, "guest", admin)

      bank_acct = bank_account_fixture(company, admin)
      funds_from_acct = funds_account_fixture(company, admin)

      attrs = %{
        "deposit_date" => Date.to_string(Date.utc_today()),
        "bank_name" => bank_acct.name,
        "bank_id" => bank_acct.id,
        "funds_from_name" => funds_from_acct.name,
        "funds_from_id" => funds_from_acct.id,
        "funds_amount" => "100.00"
      }

      assert :not_authorise = Cheque.create_deposit(attrs, company, guest)
    end
  end

  # --- DEPOSIT GET ---

  describe "get_deposit!/3" do
    test "returns deposit with bank name", %{admin: admin, company: company} do
      deposit = deposit_fixture(company, admin)
      loaded = Cheque.get_deposit!(deposit.id, company, admin)

      assert loaded.bank_name != nil
      assert loaded.funds_from_name != nil
    end
  end

  # --- RETURN CHEQUE CREATE ---

  describe "create_return_cheque/3" do
    test "creates return cheque with GL transactions", %{admin: admin, company: company} do
      return_cheque = return_cheque_fixture(company, admin)

      txns =
        Repo.all(
          from t in Transaction,
            where: t.doc_id == ^return_cheque.id and t.doc_type == "ReturnCheque"
        )

      # PDC credit + AR debit = 2
      assert length(txns) == 2

      pdc_acct = Accounting.get_account_by_name("Post Dated Cheques", company, admin)
      pdc_txn = Enum.find(txns, fn t -> t.account_id == pdc_acct.id end)
      assert Decimal.negative?(pdc_txn.amount)

      ar_acct = Accounting.get_account_by_name("Account Receivables", company, admin)
      ar_txn = Enum.find(txns, fn t -> t.account_id == ar_acct.id end)
      assert Decimal.positive?(ar_txn.amount)
    end
  end

  # --- INDEX QUERIES ---

  describe "deposit_index_query/6" do
    test "returns deposits for empty search", %{admin: admin, company: company} do
      _deposit = deposit_fixture(company, admin)

      results =
        Cheque.deposit_index_query("", "", company, admin, page: 1, per_page: 25)

      assert length(results) >= 1
    end
  end
end
