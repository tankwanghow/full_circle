defmodule Mix.Tasks.FullCircle.SeedTrading do
  @shortdoc "Seed sample grain trading data for the Trading Desk"
  @moduledoc """
  Creates demo locations, supply/sales positions, and trips so you can exercise
  the Trading Desk UI.

  ## Examples

      mix full_circle.seed_trading
      mix full_circle.seed_trading --company "Kim Poh"
      mix full_circle.seed_trading --company "Kim Poh" --email "tkh@kpst"

  All demo entities are prefixed with `DEMO` in their names/titles.
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} =
      OptionParser.parse(args,
        strict: [company: :string, email: :string, batch: :string]
      )

    case FullCircle.Trading.SampleData.seed!(opts) do
      {:ok, summary} ->
        Mix.shell().info("""

        Trading sample data created.

        Company : #{summary.company}
        User    : #{summary.user}
        Batch   : #{summary.batch}
        Desk    : #{summary.desk_path}
        Settlement (customer invoice): #{summary.settlement_path}

        Uninvoiced sales drops ready to bill: #{summary.uninvoiced_drop_count}
        Settlement-ready trips: #{Enum.join(summary.settlement_trips, ", ")}

        Supplies: #{length(summary.supplies)}  Sales: #{length(summary.sales)}  Trips: #{length(summary.trips)}

        Sample trip statuses:
        #{format_pairs(Enum.take(summary.trips, 12))}
        ...

        Log in → Trading Desk or Settlement → select drops → Create Invoice.
        """)

      other ->
        Mix.raise("Seed failed: #{inspect(other)}")
    end
  end

  defp format_pairs(list) do
    list
    |> Enum.map(fn {title, status} -> "  - [#{status}] #{title}" end)
    |> Enum.join("\n")
  end
end
