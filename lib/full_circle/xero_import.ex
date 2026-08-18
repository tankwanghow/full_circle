defmodule FullCircle.XeroImport do
  @fixture Path.expand("../../test/support/fixtures/xero_import/snapshot", __DIR__)

  def fixture_dir, do: @fixture
  def read_snapshot(dir), do: FullCircle.XeroImport.Snapshot.read(dir)
end
