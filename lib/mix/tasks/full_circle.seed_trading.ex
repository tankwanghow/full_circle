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

        Supplies:
        #{format_pairs(summary.supplies)}

        Sales:
        #{format_pairs(summary.sales)}

        Trips:
        #{format_pairs(summary.trips)}

        ~12 supply / sales / trip rows with mixed statuses; multi-warehouse stock.
        Log in and open the desk URL above.
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
