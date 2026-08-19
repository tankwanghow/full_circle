defmodule FullCircle.XeroImport do
  @fixture Path.expand("../../test/support/fixtures/xero_import/snapshot", __DIR__)

  def fixture_dir, do: @fixture
  def read_snapshot(dir), do: FullCircle.XeroImport.Snapshot.read(dir)

  def apply(snapshot, user), do: FullCircle.XeroImport.Apply.run(snapshot, user, [])

  def reconcile(snapshot, company, user),
    do: FullCircle.XeroImport.Reconcile.run(snapshot, company, user)

  def dry_run(snapshot, opts \\ %{})

  def dry_run(snapshot, opts) when is_map(snapshot) do
    {ops, errors} = FullCircle.XeroImport.Apply.plan(snapshot, opts)
    {:ok, %{counts: tally_ops(ops), errors: errors}}
  end

  def dry_run(_snapshot, _opts), do: {:error, :invalid_snapshot}

  defp tally_ops(ops) do
    Enum.reduce(ops, empty_counts(), fn
      {:skip, _reason, _row}, acc ->
        Map.update!(acc, :skipped, &(&1 + 1))

      {kind, _payload}, acc when is_map_key(acc, kind) ->
        Map.update!(acc, kind, &(&1 + 1))

      _, acc ->
        acc
    end)
  end

  defp empty_counts do
    %{
      accounts: 0,
      contacts: 0,
      invoices: 0,
      bills: 0,
      receipts: 0,
      payments: 0,
      journals: 0,
      assets: 0,
      skipped: 0
    }
  end
end
