defmodule FullCircleWeb.TransactionLive.Index do
  use FullCircleWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket}
  end
  
  @impl true
  def render(assigns) do
    ~H"""
    ...
    """
  end
end
