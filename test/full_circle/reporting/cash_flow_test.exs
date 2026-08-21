defmodule FullCircle.Reporting.CashFlowTest do
  use FullCircle.DataCase, async: true

  import FullCircle.SysFixtures
  import FullCircle.UserAccountsFixtures
  import FullCircle.AccountingFixtures
  import FullCircle.BillingFixtures

  alias FullCircle.Reporting
  alias FullCircle.Accounting.Transaction
  alias FullCircle.Repo

  defp d(n), do: Decimal.new("#{n}")

  defp txn!(com, account_id, date, amount, opts \\ []) do
    %Transaction{}
    |> Transaction.changeset(%{
      doc_type: "Journal",
      doc_no: "J#{System.unique_integer([:positive])}",
      doc_date: date,
      particulars: "t",
      amount: amount,
      company_id: com.id,
      account_id: account_id,
      contact_id: opts[:contact_id]
    })
    |> Repo.insert!()
  end

  defp acc!(com, admin, type, name) do
    account_fixture(
      %{account_type: type, name: "#{name} #{System.unique_integer([:positive])}"},
      com,
      admin
    )
  end

  setup do
    admin = user_fixture()
    com = company_fixture(admin, %{closing_month: 12, closing_day: 31})

    %{
      admin: admin,
      com: com,
      bank: acc!(com, admin, "Bank", "Bank"),
      cash: acc!(com, admin, "Cash or Equivalent", "Cash"),
      revenue: acc!(com, admin, "Revenue", "Sales"),
      expense: acc!(com, admin, "Expenses", "Rent"),
      debtors: acc!(com, admin, "Current Asset", "Debtors"),
      fixed_asset: acc!(com, admin, "Fixed Asset", "Machinery"),
      loan: acc!(com, admin, "Non-current Liability", "Bank Loan"),
      equity: acc!(com, admin, "Equity", "Share Capital")
    }
  end

  describe "cash_flow/3" do
    test "classifies non-cash movements into sections with sign flipped", ctx do
      f = ~D[2026-01-01]
      t = ~D[2026-07-31]

      # cash sale: bank +1000, revenue -1000 -> Operating +1000
      txn!(ctx.com, ctx.bank.id, ~D[2026-02-01], d(1000))
      txn!(ctx.com, ctx.revenue.id, ~D[2026-02-01], d(-1000))

      # buy machine: bank -500, fixed asset +500 -> Investing -500
      txn!(ctx.com, ctx.bank.id, ~D[2026-03-01], d(-500))
      txn!(ctx.com, ctx.fixed_asset.id, ~D[2026-03-01], d(500))

      # loan drawdown: bank +2000, loan -2000 -> Financing +2000
      txn!(ctx.com, ctx.bank.id, ~D[2026-04-01], d(2000))
      txn!(ctx.com, ctx.loan.id, ~D[2026-04-01], d(-2000))

      rows = Reporting.cash_flow(f, t, ctx.com)

      rev = Enum.find(rows, &(&1.id == ctx.revenue.id))
      fa = Enum.find(rows, &(&1.id == ctx.fixed_asset.id))
      loan = Enum.find(rows, &(&1.id == ctx.loan.id))

      assert rev.type == "Revenue"
      assert Decimal.equal?(rev.balance, d(1000))

      assert fa.type == "Fixed Asset"
      assert Decimal.equal?(fa.balance, d(-500))

      assert loan.type == "Non-current Liability"
      assert Decimal.equal?(loan.balance, d(2000))

      # no cash accounts in the rows
      refute Enum.any?(rows, &(&1.id in [ctx.bank.id, ctx.cash.id]))
    end

    test "rows are ordered Operating, Investing, Financing", ctx do
      f = ~D[2026-01-01]
      t = ~D[2026-07-31]

      txn!(ctx.com, ctx.bank.id, ~D[2026-04-01], d(2000))
      txn!(ctx.com, ctx.loan.id, ~D[2026-04-01], d(-2000))
      txn!(ctx.com, ctx.bank.id, ~D[2026-03-01], d(-500))
      txn!(ctx.com, ctx.fixed_asset.id, ~D[2026-03-01], d(500))
      txn!(ctx.com, ctx.bank.id, ~D[2026-02-01], d(1000))
      txn!(ctx.com, ctx.revenue.id, ~D[2026-02-01], d(-1000))

      types = Reporting.cash_flow(f, t, ctx.com) |> Enum.map(& &1.type)
      assert types == ["Revenue", "Fixed Asset", "Non-current Liability"]
    end

    test "movements outside the period are excluded", ctx do
      f = ~D[2026-01-01]
      t = ~D[2026-07-31]

      # before period
      txn!(ctx.com, ctx.bank.id, ~D[2025-12-15], d(700))
      txn!(ctx.com, ctx.revenue.id, ~D[2025-12-15], d(-700))
      # after period
      txn!(ctx.com, ctx.bank.id, ~D[2026-08-01], d(300))
      txn!(ctx.com, ctx.revenue.id, ~D[2026-08-01], d(-300))
      # in period
      txn!(ctx.com, ctx.bank.id, ~D[2026-05-01], d(100))
      txn!(ctx.com, ctx.revenue.id, ~D[2026-05-01], d(-100))

      [row] = Reporting.cash_flow(f, t, ctx.com)
      assert row.id == ctx.revenue.id
      assert Decimal.equal?(row.balance, d(100))
    end

    test "includes transactions carrying a contact_id", ctx do
      contact = contact_fixture(ctx.com, ctx.admin)
      f = ~D[2026-01-01]
      t = ~D[2026-07-31]

      # debtor pays: bank +800, debtors -800 (txn tagged with contact)
      txn!(ctx.com, ctx.bank.id, ~D[2026-06-01], d(800))
      txn!(ctx.com, ctx.debtors.id, ~D[2026-06-01], d(-800), contact_id: contact.id)

      [row] = Reporting.cash_flow(f, t, ctx.com)
      assert row.id == ctx.debtors.id
      assert row.type == "Current Asset"
      assert Decimal.equal?(row.balance, d(800))
    end

    test "periodic-inventory year-end journals tally across the year boundary", ctx do
      # Double-entry periodic inventory: Dec 31 books closing stock into
      # Inventory against COGS; Jan 1 expenses it back out with a BALANCED
      # opening-stock journal (Dr Opening Stock / Cr Inventory).
      inventory = acc!(ctx.com, ctx.admin, "Inventory", "Stock")
      opening_stock = acc!(ctx.com, ctx.admin, "Cost Of Goods Sold", "Opening Stock")
      closing_stock = acc!(ctx.com, ctx.admin, "Cost Of Goods Sold", "Closing Stock")

      # FY2023 closing stock 4000
      txn!(ctx.com, inventory.id, ~D[2023-12-31], d(4000))
      txn!(ctx.com, closing_stock.id, ~D[2023-12-31], d(-4000))

      # FY2024 opening stock journal — balanced
      txn!(ctx.com, opening_stock.id, ~D[2024-01-01], d(4000))
      txn!(ctx.com, inventory.id, ~D[2024-01-01], d(-4000))

      # FY2024 closing stock 3500
      txn!(ctx.com, inventory.id, ~D[2024-12-31], d(3500))
      txn!(ctx.com, closing_stock.id, ~D[2024-12-31], d(-3500))

      # a cash sale during 2024
      txn!(ctx.com, ctx.bank.id, ~D[2024-06-01], d(1000))
      txn!(ctx.com, ctx.revenue.id, ~D[2024-06-01], d(-1000))

      f = ~D[2024-01-01]
      t = ~D[2024-12-31]
      rows = Reporting.cash_flow(f, t, ctx.com)

      # Inventory moved 4000 -> 3500: a 500 stock reduction releasing cash.
      inv_row = Enum.find(rows, &(&1.id == inventory.id))
      assert Decimal.equal?(inv_row.balance, d(500))

      # rows sum to the actual cash movement
      net_change = Enum.reduce(rows, d(0), fn r, acc -> Decimal.add(r.balance, acc) end)
      cash_start = Reporting.cash_balance(Date.add(f, -1), ctx.com)
      cash_end = Reporting.cash_balance(t, ctx.com)

      assert Decimal.equal?(net_change, d(1000))
      assert Decimal.equal?(cash_end, Decimal.add(cash_start, net_change))
    end

    test "rows sum to the change in cash balance", ctx do
      f = ~D[2026-01-01]
      t = ~D[2026-07-31]

      # opening cash before the period
      txn!(ctx.com, ctx.cash.id, ~D[2025-06-01], d(5000))
      txn!(ctx.com, ctx.equity.id, ~D[2025-06-01], d(-5000))

      txn!(ctx.com, ctx.bank.id, ~D[2026-02-01], d(1000))
      txn!(ctx.com, ctx.revenue.id, ~D[2026-02-01], d(-1000))
      txn!(ctx.com, ctx.cash.id, ~D[2026-03-01], d(-450))
      txn!(ctx.com, ctx.expense.id, ~D[2026-03-01], d(450))
      txn!(ctx.com, ctx.bank.id, ~D[2026-03-15], d(-500))
      txn!(ctx.com, ctx.fixed_asset.id, ~D[2026-03-15], d(500))

      rows = Reporting.cash_flow(f, t, ctx.com)

      net_change =
        Enum.reduce(rows, d(0), fn r, acc -> Decimal.add(r.balance, acc) end)

      cash_start = Reporting.cash_balance(Date.add(f, -1), ctx.com)
      cash_end = Reporting.cash_balance(t, ctx.com)

      assert Decimal.equal?(cash_start, d(5000))
      assert Decimal.equal?(net_change, d(50))
      assert Decimal.equal?(cash_end, Decimal.add(cash_start, net_change))
    end
  end

  describe "cash_balance/2" do
    test "sums cash and bank accounts up to the date", ctx do
      txn!(ctx.com, ctx.cash.id, ~D[2026-01-10], d(300))
      txn!(ctx.com, ctx.equity.id, ~D[2026-01-10], d(-300))
      txn!(ctx.com, ctx.bank.id, ~D[2026-02-10], d(200))
      txn!(ctx.com, ctx.equity.id, ~D[2026-02-10], d(-200))

      assert Decimal.equal?(Reporting.cash_balance(~D[2026-01-31], ctx.com), d(300))
      assert Decimal.equal?(Reporting.cash_balance(~D[2026-02-28], ctx.com), d(500))
    end

    test "returns zero when there are no cash transactions", ctx do
      assert Decimal.equal?(Reporting.cash_balance(~D[2026-01-31], ctx.com), d(0))
    end
  end
end
