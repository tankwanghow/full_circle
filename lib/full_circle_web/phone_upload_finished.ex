defmodule FullCircleWeb.PhoneUploadFinished do
  @moduledoc """
  Phone upload sessions ended with "✓ Finished" (`PhoneUpload.finish/1`).
  Tokens are stateless, so ending one early needs this small ETS set. An
  entry lives as long as any token of that session could (the 600s idle
  window): a finished session never refreshes, so after that its last token
  has expired anyway. A restart forgets the set — a session finished
  moments before then works until its normal expiry, which is acceptable.
  """
  use GenServer

  @table __MODULE__
  @sweep_ms 60_000

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  # Without the table (the process restarting, or a dev server hot-reloaded
  # into this code before a restart) uploads must still work: Finished is
  # then a no-op and a session counts as not finished.
  def put(session, ttl_s) do
    if table?(), do: :ets.insert(@table, {session, now() + ttl_s})
    :ok
  end

  def finished?(session) do
    table?() and
      case :ets.lookup(@table, session) do
        [{_, until}] -> until > now()
        [] -> false
      end
  end

  defp table?, do: :ets.whereis(@table) != :undefined

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    Process.send_after(self(), :sweep, @sweep_ms)
    {:ok, nil}
  end

  @impl true
  def handle_info(:sweep, state) do
    now = now()
    :ets.select_delete(@table, [{{:_, :"$1"}, [{:<, :"$1", now}], [true]}])
    Process.send_after(self(), :sweep, @sweep_ms)
    {:noreply, state}
  end

  defp now, do: System.monotonic_time(:second)
end
