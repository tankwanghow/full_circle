defmodule FullCircle.Reporting.BalanceSheetTest do
  use FullCircle.DataCase, async: true

  import FullCircle.SysFixtures
  import FullCircle.UserAccountsFixtures
  import FullCircle.AccountingFixtures

  alias FullCircle.Reporting
  alias FullCircle.Accounting.Transaction
  alias FullCircle.Repo

  defp d(n), do: Decimal.new("#{n}")

  defp txn!(com, account_id, date, amount) do
    %Transaction{}
    |> Transaction.changeset(%{
      doc_type: "Journal",
      doc_no: "J#{System.unique_integer([:positive])}",
      doc_date: date,
      particulars: "t",
      amount: amount,
      company_id: com.id,
      account_id: account_id
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
    %{admin: admin, com: com}
  end

  describe "balance_sheet/2 with double-entry periodic inventory" do
    test "inventory carries its full transaction history", ctx do
      inventory = acc!(ctx.com, ctx.admin, "Inventory", "Stock")
      opening_stock = acc!(ctx.com, ctx.admin, "Cost Of Goods Sold", "Opening Stock")
      closing_stock = acc!(ctx.com, ctx.admin, "Cost Of Goods Sold", "Closing Stock")

      # FY2023 closing stock 4000
      txn!(ctx.com, inventory.id, ~D[2023-12-31], d(4000))
      txn!(ctx.com, closing_stock.id, ~D[2023-12-31], d(-4000))

      # FY2024 opening journal — balanced double entry
      txn!(ctx.com, opening_stock.id, ~D[2024-01-01], d(4000))
      txn!(ctx.com, inventory.id, ~D[2024-01-01], d(-4000))

      # FY2024 closing stock 3500
      txn!(ctx.com, inventory.id, ~D[2024-12-31], d(3500))
      txn!(ctx.com, closing_stock.id, ~D[2024-12-31], d(-3500))

      rows = Reporting.balance_sheet(~D[2024-12-31], ctx.com)
      inv_row = Enum.find(rows, &(&1.id == inventory.id))

      assert Decimal.equal?(inv_row.balance, d(3500))
    end

    test "trial balance sums to zero across the year boundary", ctx do
      inventory = acc!(ctx.com, ctx.admin, "Inventory", "Stock")
      opening_stock = acc!(ctx.com, ctx.admin, "Cost Of Goods Sold", "Opening Stock")
      bank = acc!(ctx.com, ctx.admin, "Bank", "Maybank")
      revenue = acc!(ctx.com, ctx.admin, "Revenue", "Sales")
      equity = acc!(ctx.com, ctx.admin, "Equity", "Retained Profits")

      # FY2023: a sale booked as closing stock, then closed into equity
      txn!(ctx.com, inventory.id, ~D[2023-12-31], d(4000))
      txn!(ctx.com, revenue.id, ~D[2023-12-31], d(-4000))
      txn!(ctx.com, revenue.id, ~D[2023-12-31], d(4000))
      txn!(ctx.com, equity.id, ~D[2023-12-31], d(-4000))

      # FY2024: balanced opening journal + a cash sale
      txn!(ctx.com, opening_stock.id, ~D[2024-01-01], d(4000))
      txn!(ctx.com, inventory.id, ~D[2024-01-01], d(-4000))
      txn!(ctx.com, bank.id, ~D[2024-03-01], d(1000))
      txn!(ctx.com, revenue.id, ~D[2024-03-01], d(-1000))

      total =
        Reporting.trail_balance(~D[2024-06-30], ctx.com)
        |> Enum.reduce(d(0), fn r, acc -> Decimal.add(r.balance, acc) end)

      # BS holds 0 inventory + 1000 bank - 4000 equity; sliced P&L holds
      # 4000 opening stock - 1000 revenue: total is zero.
      assert Decimal.equal?(total, d(0))
    end
  end
end
