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
        Settlement: #{summary.settlement_path}

        Uninvoiced customer drops: #{summary.uninvoiced_drop_count}
        Unbilled supplier loads:   #{summary.unbilled_load_count}
        Unbilled transport hauls:  #{summary.unbilled_transport_count}

        Settlement singles: #{Enum.join(summary.settlement_trips, ", ")}

        Multi-load / multi-drop trips (ref · status · loads×drops):
        #{format_multi(summary.multi_line_trips)}

        Supplies: #{length(summary.supplies)}  Sales: #{length(summary.sales)}  Trips: #{length(summary.trips)}

        Log in → Desk (see MULTI vehicles) or Settlement tabs:
          Customer invoices | Supplier bills | Transport bills
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

  defp format_multi(list) do
    list
    |> Enum.map(fn {ref, status, n_loads, n_drops} ->
      "  - [#{status}] #{ref}  #{n_loads}L × #{n_drops}D"
    end)
    |> Enum.join("\n")
  end
end
