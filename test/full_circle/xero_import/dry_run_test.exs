defmodule FullCircle.XeroImport.DryRunTest do
  use FullCircle.DataCase

  alias FullCircle.Repo
  alias FullCircle.XeroImport

  setup do
    {:ok, snap} = XeroImport.read_snapshot(XeroImport.fixture_dir())
    name = "Xero DryRun #{System.unique_integer([:positive])}"
    %{snap: snap, name: name}
  end

  test "dry-run reports INV-000123 and skips draft", %{snap: snap} do
    assert {:ok, %{counts: c, errors: []}} = XeroImport.dry_run(snap, %{})
    assert c.invoices == 3
    assert c.skipped >= 1
  end

  test "dry-run captures missing allocation without writing", %{snap: snap} = ctx do
    companies_before = Repo.aggregate(from(c in FullCircle.Sys.Company), :count)

    snap =
      put_in(snap.payments, [
        %{
          "PaymentID" => "pay-bad",
          "Invoice" => %{"InvoiceID" => "nope"},
          "Amount" => 1.0,
          "Date" => "2024-02-01",
          "Account" => %{"AccountID" => "ac-bank"},
          "Status" => "AUTHORISED"
        }
      ])

    assert {:ok, %{errors: errors}} = XeroImport.dry_run(snap, %{})
    assert Enum.any?(errors, &match?({:missing_allocation_target, _, _}, &1))
    refute Repo.exists?(from c in FullCircle.Sys.Company, where: c.name == ^ctx.name)
    assert Repo.aggregate(from(c in FullCircle.Sys.Company), :count) == companies_before
  end

  test "mix --auth without credentials exits 1" do
    missing = "/tmp/xero-no-creds-#{System.unique_integer([:positive])}"

    assert catch_exit(
             Mix.Task.rerun("full_circle.import_xero", ["--auth", "--credentials", missing])
           ) == {:shutdown, 1}
  end

  test "mix --snapshot without credentials exits 1" do
    missing = "/tmp/xero-no-creds-#{System.unique_integer([:positive])}"

    assert catch_exit(
             Mix.Task.rerun("full_circle.import_xero", ["--snapshot", "--credentials", missing])
           ) == {:shutdown, 1}
  end

  test "mix --dry-run against fixture with --log false" do
    dir = XeroImport.fixture_dir()
    log = Path.join(dir, "last_run.log")
    File.rm(log)

    Mix.Task.rerun("full_circle.import_xero", [
      "--dry-run",
      "--snapshot-dir",
      dir,
      "--log",
      "false"
    ])

    refute File.exists?(log)
  end

  test "mix --apply without user exits 1" do
    System.delete_env("FC_IMPORT_USER")

    assert catch_exit(
             Mix.Task.rerun("full_circle.import_xero", [
               "--apply",
               "--snapshot-dir",
               XeroImport.fixture_dir(),
               "--log",
               "false"
             ])
           ) == {:shutdown, 1}
  end
end
