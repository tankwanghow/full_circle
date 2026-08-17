defmodule FullCircle.UserQueries.SqlGeneratorTest do
  use ExUnit.Case, async: true

  alias FullCircle.UserQueries.SqlGenerator

  @catalog [
    "fct_invoices",
    "fct_invoice_details",
    "fct_contacts",
    "fct_transactions",
    "fct_accounts"
  ]

  describe "extract_sql/1" do
    test "takes a fenced sql block" do
      text = """
      Sure, here you go:
      ```sql
      SELECT i.invoice_no FROM fct_invoices i
      ```
      """

      assert {:ok, "SELECT i.invoice_no FROM fct_invoices i"} = SqlGenerator.extract_sql(text)
    end

    test "takes a bare SELECT" do
      assert {:ok, sql} = SqlGenerator.extract_sql("SELECT * FROM fct_contacts")
      assert sql == "SELECT * FROM fct_contacts"
    end

    test "rejects text with no SQL" do
      assert {:error, _} = SqlGenerator.extract_sql("I cannot help with that.")
    end
  end

  describe "validate_sql/2" do
    test "accepts a select against fct_ functions" do
      sql = """
      SELECT i.invoice_no, c.name
      FROM fct_invoices i
      JOIN fct_contacts c ON c.id = i.contact_id
      """

      assert :ok = SqlGenerator.validate_sql(sql, @catalog)
    end

    test "accepts a CTE that only reads fct_ functions" do
      sql = """
      WITH unpaid AS (
        SELECT * FROM fct_invoices
      )
      SELECT * FROM unpaid
      """

      assert :ok = SqlGenerator.validate_sql(sql, @catalog)
    end

    test "rejects a raw table" do
      assert {:error, msg} =
               SqlGenerator.validate_sql("SELECT * FROM invoices", @catalog)

      assert msg =~ "fct_"
    end

    test "rejects write statements" do
      assert {:error, _} =
               SqlGenerator.validate_sql(
                 "SELECT * FROM fct_invoices; DELETE FROM invoices",
                 @catalog
               )
    end

    test "rejects an unknown fct_ name" do
      assert {:error, msg} =
               SqlGenerator.validate_sql("SELECT * FROM fct_not_a_table", @catalog)

      assert msg =~ "fct_not_a_table"
    end
  end

  describe "generate/2" do
    test "returns cleaned SQL from the model" do
      client = fn _settings, _sys, _user ->
        {:ok, "```sql\nSELECT name FROM fct_contacts\n```", %{}}
      end

      assert {:ok, "SELECT name FROM fct_contacts"} =
               SqlGenerator.generate("list contacts", %{},
                 client: client,
                 catalog: @catalog,
                 columns: ""
               )
    end

    test "rejects a blank prompt without calling the model" do
      client = fn _, _, _ -> flunk("LLM should not be called") end

      assert {:error, _} = SqlGenerator.generate("  ", %{}, client: client, catalog: @catalog)
    end

    test "rejects model SQL that hits a raw table" do
      client = fn _, _, _ -> {:ok, "SELECT * FROM invoices", %{}} end

      assert {:error, msg} =
               SqlGenerator.generate("invoices", %{},
                 client: client,
                 catalog: @catalog,
                 columns: ""
               )

      assert msg =~ "fct_"
    end

    test "sends the schema card to the model" do
      test_pid = self()

      client = fn _settings, system, _user ->
        send(test_pid, {:system, system})
        {:ok, "SELECT name FROM fct_contacts", %{}}
      end

      assert {:ok, _} =
               SqlGenerator.generate("list contacts", %{},
                 client: client,
                 catalog: @catalog,
                 columns: ""
               )

      assert_receive {:system, system}
      assert system =~ "fct_invoice_details.invoice_id"
      assert system =~ "fct_transactions.amount"
      assert system =~ "Account Receivables"
      assert system =~ "fct_contacts"
    end

    test "embeds this company's account names in the system prompt" do
      test_pid = self()

      client = fn _settings, system, _user ->
        send(test_pid, {:system, system})
        {:ok, "SELECT name FROM fct_accounts", %{}}
      end

      assert {:ok, _} =
               SqlGenerator.generate("list trade debtors", %{},
                 client: client,
                 catalog: @catalog,
                 columns: "",
                 accounts: "Account Receivables (Current Asset), Account Payables (Current Liability)"
               )

      assert_receive {:system, system}
      assert system =~ "Account Receivables (Current Asset)"
      assert system =~ "never invent"
    end

    test "embeds supplied column lists in the system prompt" do
      test_pid = self()

      columns = """
      fct_invoices: id, invoice_no, invoice_date, contact_id
      fct_contacts: id, name, address1
      """

      client = fn _settings, system, _user ->
        send(test_pid, {:system, system})
        {:ok, "SELECT name FROM fct_contacts", %{}}
      end

      assert {:ok, _} =
               SqlGenerator.generate("list contacts", %{},
                 client: client,
                 catalog: @catalog,
                 columns: columns
               )

      assert_receive {:system, system}
      assert system =~ "fct_invoices: id, invoice_no, invoice_date, contact_id"
    end

    test "repairs once when the dry-run fails" do
      {:ok, agent} =
        Agent.start_link(fn ->
          [
            "SELECT invoice_amount FROM fct_invoices",
            "SELECT invoice_no FROM fct_invoices"
          ]
        end)

      client = fn _settings, _sys, user ->
        sql = Agent.get_and_update(agent, fn [h | t] -> {h, t} end)
        send(self(), {:user_prompt, user})
        {:ok, sql, %{}}
      end

      dry_run = fn
        "SELECT invoice_amount FROM fct_invoices" ->
          {:error, "column \"invoice_amount\" does not exist"}

        _ ->
          :ok
      end

      assert {:ok, "SELECT invoice_no FROM fct_invoices"} =
               SqlGenerator.generate("invoice list", %{},
                 client: client,
                 catalog: @catalog,
                 columns: "",
                 dry_run: dry_run
               )

      assert_received {:user_prompt, first}
      assert_received {:user_prompt, repair}
      refute first =~ "invoice_amount"
      assert repair =~ "invoice_amount"
      assert repair =~ "does not exist"
    end

    test "does not call the model a second time when dry-run succeeds" do
      {:ok, agent} = Agent.start_link(fn -> 0 end)

      client = fn _, _, _ ->
        Agent.update(agent, &(&1 + 1))
        {:ok, "SELECT name FROM fct_contacts", %{}}
      end

      assert {:ok, "SELECT name FROM fct_contacts"} =
               SqlGenerator.generate("contacts", %{},
                 client: client,
                 catalog: @catalog,
                 columns: "",
                 dry_run: fn _ -> :ok end
               )

      assert Agent.get(agent, & &1) == 1
    end
  end
end


