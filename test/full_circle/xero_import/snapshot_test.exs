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
end
