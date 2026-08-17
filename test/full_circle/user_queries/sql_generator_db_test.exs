defmodule FullCircle.UserQueries.SqlGeneratorDbTest do
  use FullCircle.DataCase

  alias FullCircle.UserQueries
  alias FullCircle.UserQueries.SqlGenerator

  import FullCircle.SysFixtures
  import FullCircle.UserAccountsFixtures

  test "account_directory lists seeded control accounts for the company" do
    admin = user_fixture()
    company = company_fixture(admin, %{})

    text = SqlGenerator.account_directory(company.id)

    assert text =~ "Account Receivables"
    refute text =~ "Trade Debtors"
  end

  test "column_catalog lists stored invoice columns and omits virtual totals" do
    text = SqlGenerator.column_catalog()

    assert text =~ ~r/fct_invoices:.*invoice_no/
    assert text =~ ~r/fct_invoices:.*invoice_date/
    refute text =~ "invoice_amount"
    refute text =~ "fct_users:"
  end

  test "dry_run accepts injected fct_ SQL and rejects a missing column" do
    admin = user_fixture()
    company = company_fixture(admin, %{})

    assert :ok =
             SqlGenerator.dry_run("SELECT name FROM fct_contacts", company.id)

    assert {:error, msg} =
             SqlGenerator.dry_run("SELECT invoice_amount FROM fct_invoices", company.id)

    assert msg =~ "invoice_amount"
  end

  test "generate_sql retries after a real missing-column error" do
    admin = user_fixture()
    company = company_fixture(admin, %{})

    {:ok, agent} =
      Agent.start_link(fn ->
        [
          "SELECT invoice_amount FROM fct_invoices",
          "SELECT invoice_no, invoice_date FROM fct_invoices"
        ]
      end)

    client = fn _, _, _ ->
      {:ok, Agent.get_and_update(agent, fn [h | t] -> {h, t} end), %{}}
    end

    assert {:ok, sql} =
             UserQueries.generate_sql("invoices", %{},
               client: client,
               company_id: company.id
             )

    assert sql =~ "invoice_no"
    refute sql =~ "invoice_amount"
  end
end
