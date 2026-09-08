defmodule FullCircle.PunchGate.PhotoPruner do
  @moduledoc """
  Deletes punch photos older than the retention window, keeping the punch rows.

  There is no job runner in this project, so this is a plain supervised process
  that wakes daily. It ships with the release, which means nothing to configure
  on a server and nothing to forget on a new deploy. It assumes a single node —
  with more than one, each would run its own copy (harmless but wasteful, since
  the work is idempotent).

  Note this is a no-op until the oldest punches cross the window: the gate went
  live in 2026-09, so nothing is prunable until late 2028. The tests in
  `FullCircle.PunchGateTest` are the real evidence it behaves. To see what it
  would do before then, call it directly with a nearer cutoff:

      FullCircle.PunchGate.prune_photos_before(
        DateTime.add(DateTime.utc_now(), -30, :day),
        dry_run: true
      )
  """
  use GenServer
  require Logger

  alias FullCircle.PunchGate

  @day_ms 24 * 60 * 60 * 1000
  @default_retention_months 24
  # Late enough after boot that a deploy is not competing with startup work.
  @first_run_ms 5 * 60 * 1000

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    if enabled?(), do: Process.send_after(self(), :prune, @first_run_ms)
    {:ok, nil}
  end

  @impl true
  def handle_info(:prune, state) do
    prune()
    Process.send_after(self(), :prune, @day_ms)
    {:noreply, state}
  end

  @doc "Runs one pass now. Safe to call by hand from a release console."
  def prune do
    months =
      Application.get_env(
        :full_circle,
        :punch_photo_retention_months,
        @default_retention_months
      )

    # Calendar months, not 30-day approximations: 24 * 30 days is 23.7 months.
    cutoff = Timex.shift(DateTime.utc_now(), months: -months)

    case PunchGate.prune_photos_before(cutoff) do
      {:ok, 0} ->
        :ok

      {:ok, n} ->
        Logger.info("punch photo pruner: removed #{n} photos captured before #{cutoff}")
        :ok
    end
  rescue
    e ->
      # Never take the supervision tree down over housekeeping; retry tomorrow.
      Logger.error("punch photo pruner failed: #{Exception.message(e)}")
      :error
  end

  defp enabled?, do: Application.get_env(:full_circle, :punch_photo_prune_enabled, true)
end
