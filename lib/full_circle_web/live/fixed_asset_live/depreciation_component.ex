defmodule FullCircleWeb.FixedAssetLive.DepreciationComponent do
  use FullCircleWeb, :live_component

  alias FullCircle.Accounting.{FixedAsset, FixedAssetDepreciation}
  alias FullCircle.StdInterface

  @impl true
  def mount(socket) do
    {:ok, socket}
  end

  @impl true
  def update(assigns, socket) do
    socket = socket |> assign(assigns)

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <p class="w-full text-2xl text-center font-medium"><%= "#{@title} #{@object.name}" %></p>
      <div class="font-medium flex flex-row flex-wrap text-center mt-2 tracking-tighter">
        <div class="detail-header w-3/12 shrink-[3] grow-[3]"><%= gettext("Date") %></div>
        <div class="detail-header w-3/12 shrink-[3] grow-[3]"><%= gettext("Cost Basis") %></div>
        <div class="detail-header w-3/12 shrink-[1] grow-[1]">
          <%= gettext("Cume Depreciation") %>
        </div>
        <div class="detail-header w-3/12 shrink-[1] grow-[1]">
          <%= gettext("Current Depreciation") %>
        </div>
      </div>
      <.link phx-click={:add_depreciation} phx-target={@myself}>
        <.icon name="hero-plus-circle" class="w-5 h-5" /><%= gettext("Add Depreciation") %>
      </.link>
    </div>
    """
  end
end
