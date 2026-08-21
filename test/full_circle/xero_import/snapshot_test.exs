defmodule FullCircle.XeroImport.SnapshotTest do
  use ExUnit.Case, async: true

  alias FullCircle.XeroImport
  alias FullCircle.XeroImport.Snapshot

  test "read/1 loads the committed fixture snapshot" do
    assert {:ok, snap} = Snapshot.read(XeroImport.fixture_dir())
    assert snap.organisation["Name"] == "Fixture Org"
    assert length(snap.accounts) >= 4
    assert Enum.any?(snap.invoices, &(&1["InvoiceNumber"] == "INV-000123"))
    assert snap.reports["trial_balance"] != nil
  end

  test "read/1 errors when a required file is missing" do
    dir = System.tmp_dir!() |> Path.join("xero-empty-#{System.unique_integer()}")
    File.mkdir_p!(dir)
    assert {:error, {:missing_file, _}} = Snapshot.read(dir)
  end

  describe "extra_docs.json sidecar" do
    defp copy_fixture! do
      dir =
        System.tmp_dir!()
        |> Path.join("xero-extra-#{System.unique_integer([:positive])}/snapshot")

      File.mkdir_p!(dir)
      for f <- File.ls!(XeroImport.fixture_dir()) do
        File.cp!(Path.join(XeroImport.fixture_dir(), f), Path.join(dir, f))
      end

      on_exit(fn -> File.rm_rf(Path.dirname(dir)) end)
      dir
    end

    defp extra_docs do
      %{
        "contacts" => [%{"ContactID" => "x-emp-1", "Name" => "MOK CHUA KWAN"}],
        "invoices" => [
          %{
            "Type" => "ACCPAY",
            "Status" => "AUTHORISED",
            "CurrencyCode" => "MYR",
            "InvoiceID" => "xwpi-pr3-kwsp",
            "InvoiceNumber" => "PR-0003-KWSP",
            "Date" => "2021-03-02",
            "Total" => 660.0,
            "LineAmountTypes" => "NoTax",
            "Contact" => %{"ContactID" => "x-emp-1"},
            "LineItems" => [
              %{"AccountCode" => "477", "Quantity" => 1, "UnitAmount" => 660.0,
                "LineAmount" => 660.0, "TaxType" => "NONE"}
            ]
          }
        ],
        "payments" => [
          %{
            "PaymentID" => "XWPAY-1",
            "Status" => "AUTHORISED",
            "Date" => "2021-03-20",
            "Amount" => 660.0,
            "Account" => %{"AccountID" => "ac-bank"},
            "Invoice" => %{"InvoiceID" => "xwpi-pr3-kwsp"}
          }
        ],
        "bank_transactions" => [],
        "manual_journals" => []
      }
    end

    test "read/1 appends sidecar docs from the snapshot dir and recomputes totals" do
      dir = copy_fixture!()
      File.write!(Path.join(dir, "extra_docs.json"), Jason.encode!(extra_docs()))

      assert {:ok, snap} = Snapshot.read(dir)
      assert Enum.any?(snap.contacts, &(&1["ContactID"] == "x-emp-1"))
      assert Enum.any?(snap.invoices, &(&1["InvoiceID"] == "xwpi-pr3-kwsp"))
      assert Enum.any?(snap.payments, &(&1["PaymentID"] == "XWPAY-1"))

      # bill_totals recomputed over merged invoices: fixture {1, 30.0} + 660.0
      assert snap.reports["bill_totals"] == %{"count" => 2, "amount" => 690.0}
      assert snap.reports["invoice_totals"] == %{"count" => 3, "amount" => 170.0}
    end

    test "read/1 falls back to extra_docs.json in the parent dir" do
      dir = copy_fixture!()
      File.write!(Path.join(Path.dirname(dir), "extra_docs.json"), Jason.encode!(extra_docs()))

      assert {:ok, snap} = Snapshot.read(dir)
      assert Enum.any?(snap.invoices, &(&1["InvoiceID"] == "xwpi-pr3-kwsp"))
    end

    test "read/1 without a sidecar leaves the snapshot untouched" do
      dir = copy_fixture!()
      assert {:ok, snap} = Snapshot.read(dir)
      refute Enum.any?(snap.invoices, &(&1["InvoiceID"] == "xwpi-pr3-kwsp"))
      assert snap.reports["bill_totals"] == %{"count" => 1, "amount" => 30.0}
    end

    test "read/1 rejects unknown sidecar keys" do
      dir = copy_fixture!()
      File.write!(Path.join(dir, "extra_docs.json"), Jason.encode!(%{"accounts" => []}))
      assert {:error, {:invalid_extra_docs_key, "accounts"}} = Snapshot.read(dir)
    end
  end
end
