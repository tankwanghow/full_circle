defmodule FullCircle.Reporting.StatementTest do
  @moduledoc """
  The detail window on a contact statement.

  Without `days` each contact starts at the month of its own last transaction.
  `days` widens that window back from the To date, and can only widen it — a
  contact never loses the month it last traded in, so a statement is never a
  page containing nothing but a brought-forward line.
  """
  use FullCircle.DataCase, async: true

  alias FullCircle.Reporting
  alias FullCircle.Accounting.Transaction

  import FullCircle.UserAccountsFixtures
  import FullCircle.SysFixtures
  import FullCircle.BillingFixtures

  @edate ~D[2026-09-21]

  setup do
    admin = user_fixture()
    company = company_fixture(admin, %{})
    contact = contact_fixture(company, admin)
    account = FullCircle.Accounting.get_account_by_name("General Sales", company, admin)

    %{admin: admin, company: company, contact: contact, account: account}
  end

  defp txn(%{company: company, account: account}, contact, date, amount) do
    FullCircle.Repo.insert!(%Transaction{
      doc_type: "Invoice",
      doc_date: date,
      doc_no: "INV-#{Date.to_iso8601(date)}",
      particulars: "sale",
      amount: Decimal.new("#{amount}"),
      company_id: company.id,
      contact_id: contact.id,
      account_id: account.id
    })
  end

  defp statement(%{company: company}, contact, days) do
    [statement] =
      Reporting.statements([contact.id], @edate, company, [30, 60, 90, 120], days)

    statement
  end

  defp detail(ctx, contact, days), do: statement(ctx, contact, days).transactions

  defp dates(txns), do: Enum.map(txns, & &1.doc_date)

  defp brought_forward(txns) do
    Enum.find(txns, &(&1.particulars == "Balance Brought Forward"))
  end

  defp amount(row), do: Decimal.new("#{row.amount}")

  describe "statements/5 detail window" do
    setup ctx do
      txn(ctx, ctx.contact, ~D[2026-03-10], 100)
      txn(ctx, ctx.contact, ~D[2026-06-15], 200)
      txn(ctx, ctx.contact, ~D[2026-09-05], 300)
      txn(ctx, ctx.contact, ~D[2026-09-18], 400)
      :ok
    end

    test "without days it starts at the month of the last transaction", ctx do
      rows = detail(ctx, ctx.contact, nil)

      assert dates(rows) == [~D[2026-08-31], ~D[2026-09-05], ~D[2026-09-18]]
      assert Decimal.equal?(amount(brought_forward(rows)), Decimal.new("300"))
    end

    test "days widens the window back from the To date", ctx do
      rows = detail(ctx, ctx.contact, 120)

      assert dates(rows) == [
               ~D[2026-05-23],
               ~D[2026-06-15],
               ~D[2026-09-05],
               ~D[2026-09-18]
             ]

      assert Decimal.equal?(amount(brought_forward(rows)), Decimal.new("100"))
    end

    test "the statement carries the start date its detail used", ctx do
      assert statement(ctx, ctx.contact, 120).sdate == ~D[2026-05-24]
      assert statement(ctx, ctx.contact, nil).sdate == ~D[2026-09-01]
    end

    test "days never narrows below the month last traded in", ctx do
      # 5 days back is 2026-09-16, which would clip the 2026-09-05 sale.
      rows = detail(ctx, ctx.contact, 5)

      assert dates(rows) == [~D[2026-08-31], ~D[2026-09-05], ~D[2026-09-18]]
      assert Decimal.equal?(amount(brought_forward(rows)), Decimal.new("300"))
    end
  end

  describe "statements/5 for a dormant contact" do
    test "keeps the month it last traded in, however far back", ctx do
      txn(ctx, ctx.contact, ~D[2026-03-10], 100)

      rows = detail(ctx, ctx.contact, 30)

      assert dates(rows) == [~D[2026-02-28], ~D[2026-03-10]]
      assert Decimal.equal?(amount(brought_forward(rows)), Decimal.new("0"))
    end

    test "the start date reported is the floored one, not the requested one", ctx do
      txn(ctx, ctx.contact, ~D[2026-03-10], 100)

      assert statement(ctx, ctx.contact, 30).sdate == ~D[2026-03-01]
    end

    test "a contact with no transactions at all still renders", ctx do
      rows = detail(ctx, ctx.contact, 90)

      assert Decimal.equal?(amount(brought_forward(rows)), Decimal.new("0"))
    end
  end
end
