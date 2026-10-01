defmodule FullCircleWeb.FixedAssetLive.IndexComponent do
  use FullCircleWeb, :live_component

  import FullCircleWeb.ListComponents

  @impl true
  def mount(socket) do
    {:ok, socket}
  end

  @impl true
  def update(assigns, socket) do
    {:ok, socket |> assign(assigns)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class={[row_class(), line_class()]}>
      <div
        class="flex-1 min-w-0 flex items-center gap-1 overflow-hidden"
        title={
          Enum.join(
            [
              "#{gettext("Fixed Asset Account:")} #{@obj.asset_ac_name}",
              "#{gettext("Depreciation Account:")} #{@obj.depre_ac_name}",
              "#{gettext("Cume Depreciation Account:")} #{@obj.cume_depre_ac_name}",
              "#{gettext("Disposal Account:")} #{@obj.disp_fund_ac_name}",
              @obj.descriptions
            ],
            "\n"
          )
        }
      >
        <.link
          navigate={~p"/companies/#{@current_company.id}/fixed_assets/#{@obj.id}/edit"}
          class="min-w-0 truncate hover:font-bold text-blue-600"
        >
          {@obj.name}
        </.link>
        <.chip :if={@obj.status != "Active"} kind={:bad}>{@obj.status}</.chip>
      </div>
      <div class="w-28 shrink-0 text-right tabular-nums">{money(@obj.pur_price)}</div>
      <div class="w-32 shrink-0 text-right tabular-nums">
        <.link
          :if={@obj.depre_method != "No Depreciation"}
          navigate={
            ~p"/companies/#{@current_company.id}/fixed_assets/#{@obj.id}/depreciations?terms=#{@terms}"
          }
          class="hover:underline text-blue-600"
        >
          {money(@obj.cume_depre || Decimal.new("0"))}
        </.link>
        <span :if={@obj.depre_method == "No Depreciation"} class="text-slate-400">—</span>
      </div>
      <div class="w-28 shrink-0 text-right tabular-nums">
        <.link
          navigate={
            ~p"/companies/#{@current_company.id}/fixed_assets/#{@obj.id}/disposals?terms=#{@terms}"
          }
          class="hover:underline text-blue-600"
        >
          {money(@obj.cume_disp || Decimal.new("0"))}
        </.link>
      </div>
      <div class="w-28 shrink-0 text-right tabular-nums">
        {@obj.pur_price
        |> Decimal.sub(@obj.cume_disp || Decimal.new("0"))
        |> Decimal.sub(@obj.cume_depre || Decimal.new("0"))
        |> money()}
      </div>
      <div class={["w-32 shrink-0 truncate", muted_class()]}>
        {Number.Percentage.number_to_percentage(Decimal.mult(@obj.depre_rate, 100))} · {@obj.depre_interval}
      </div>
    </div>
    """
  end
end
