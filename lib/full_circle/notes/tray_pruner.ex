defmodule FullCircle.Notes.TrayPruner do
  @moduledoc """
  Deletes write-box trays and phone scan folders older than a day: files
  picked or scanned and never saved or cancelled. A plain supervised process
  that wakes daily, like `PunchGate.PhotoPruner` (there is no job runner).
  """
  use GenServer
  require Logger

  alias FullCircle.Notes.Trays

  @day_ms 24 * 60 * 60 * 1000
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
    {:ok, counts} = Trays.prune_before(DateTime.add(DateTime.utc_now(), -1, :day))

    if counts.trays + counts.scans > 0,
      do: Logger.info("note tray pruner: #{inspect(counts)}")

    :ok
  rescue
    e ->
      # Never take the supervision tree down over housekeeping; retry tomorrow.
      Logger.error("note tray pruner failed: #{Exception.message(e)}")
      :error
  end

  defp enabled?, do: Application.get_env(:full_circle, :note_tray_prune_enabled, true)
end
