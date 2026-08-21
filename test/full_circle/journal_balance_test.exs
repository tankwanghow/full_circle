defmodule FullCircle.JournalBalanceTest do
  use FullCircle.DataCase

  describe "journal must balance" do
    setup do
      %{admin: admin, company: company} = FullCircle.BillingFixtures.billing_setup()
      %{admin: admin, company: company}
    end

    test "an unbalanced journal is rejected", %{company: company, admin: admin} do
      assert {:error, :create_journal, changeset, _} =
               FullCircle.JournalEntry.create_journal(
                 journal_attrs(company, admin, "100.00", "-99.00"),
                 company,
                 admin
               )

      assert %{journal_balance: [_ | _]} = errors_on(changeset)
    end

    test "a balanced journal is accepted", %{company: company, admin: admin} do
      assert {:ok, %{create_journal: _}} =
               FullCircle.JournalEntry.create_journal(
                 journal_attrs(company, admin, "100.00", "-100.00"),
                 company,
                 admin
               )
    end
  end

  defp journal_attrs(company, user, debit_amt, credit_amt) do
    debit = FullCircle.Accounting.get_account_by_name("General Purchases", company, user)
    credit = FullCircle.Accounting.get_account_by_name("General Sales", company, user)

    %{
      "journal_date" => Date.to_string(Date.utc_today()),
      "transactions" => %{
        "0" => %{
          "account_id" => debit.id,
          "account_name" => debit.name,
          "particulars" => "Test journal debit",
          "amount" => debit_amt,
          "_persistent_id" => "0"
        },
        "1" => %{
          "account_id" => credit.id,
          "account_name" => credit.name,
          "particulars" => "Test journal credit",
          "amount" => credit_amt,
          "_persistent_id" => "1"
        }
      }
    }
  end
end
