defmodule FullCircle.XeroImport.Snapshot do
  @files ~w(
    organisation accounts tax_rates contacts items invoices credit_notes
    bank_transactions payments manual_journals bank_transfers
    fixed_assets conversion_balances reports
  )a

  def read(dir) do
    Enum.reduce_while(@files, {:ok, %{}}, fn key, {:ok, acc} ->
      path = Path.join(dir, "#{key}.json")

      cond do
        not File.exists?(path) ->
          {:halt, {:error, {:missing_file, path}}}

        true ->
          with {:ok, bin} <- File.read(path),
               {:ok, json} <- Jason.decode(bin) do
            {:cont, {:ok, Map.put(acc, key, json)}}
          else
            err -> {:halt, {:error, err}}
          end
      end
    end)
  end
end
