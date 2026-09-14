defmodule FullCircle.PunchGate.IngestLogPruner do
  @moduledoc """
  Deletes `punch_ingest_logs` rows (and their JPEGs) older than the retention
  window.

  Same shape as `PhotoPruner` and for the same reason: there is no job runner
  in this project, so this is a plain supervised process that wakes daily and
  ships with the release. Single node assumed — with more than one, each runs
  its own copy, which is wasteful but harmless because the work is idempotent.

  Unlike `PhotoPruner` this one deletes **rows**, not just files: the ingest log
  is an operational breadcrumb trail, not a register. `time_attendences` and
  its 24-month photos are untouched.

  To see what it would do without deleting anything:

      FullCircle.PunchGate.prune_ingest_logs_before(
        Timex.shift(DateTime.utc_now(), months: -3),
        dry_run: true
      )
  """
  use GenServer
  require Logger

  alias FullCircle.PunchGate

  @day_ms 24 * 60 * 60 * 1000
  @default_retention_months 3
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
        :punch_ingest_log_retention_months,
        @default_retention_months
      )

    # Calendar months, not 30-day approximations.
    cutoff = Timex.shift(DateTime.utc_now(), months: -months)

    case PunchGate.prune_ingest_logs_before(cutoff) do
      {:ok, 0} ->
        :ok

      {:ok, n} ->
        Logger.info("punch ingest log pruner: removed #{n} rows received before #{cutoff}")
        :ok
    end
  rescue
    e ->
      # Never take the supervision tree down over housekeeping; retry tomorrow.
      Logger.error("punch ingest log pruner failed: #{Exception.message(e)}")
      :error
  end

  defp enabled?, do: Application.get_env(:full_circle, :punch_ingest_log_prune_enabled, true)
end
