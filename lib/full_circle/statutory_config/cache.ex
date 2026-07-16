defmodule FullCircle.StatutoryConfig.Cache do
  @moduledoc false
  use GenServer

  @table __MODULE__

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, read_concurrency: true])
    {:ok, nil}
  end

  def fetch(key, fun) do
    case :ets.lookup(@table, key) do
      [{^key, value}] ->
        value

      [] ->
        value = fun.()
        :ets.insert(@table, {key, value})
        value
    end
  end

  def invalidate(company_id) do
    :ets.match_delete(@table, {{company_id, :_, :_}, :_})
    :ok
  end
end
