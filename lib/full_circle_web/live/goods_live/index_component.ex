defmodule FullCircleWeb.GoodLive.IndexComponent do
  use FullCircleWeb, :live_component

  import FullCircleWeb.ListComponents

  @impl true
  def mount(socket) do
    {:ok, socket}
  end

  @impl true
  def update(assigns, socket) do
    {:ok, socket |> assign(assigns) |> assign_new(:note_count, fn -> 0 end)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class={[row_class(@ex_class), line_class()]}>
      <div class="w-[22%] shrink-0 min-w-0 flex items-center gap-1 overflow-hidden">
        <.link
          class="min-w-0 truncate text-blue-600 hover:font-bold"
          navigate={~p"/companies/#{@current_company}/goods/#{@obj.id}/edit"}
        >
          {@obj.name}
        </.link>
        <span class={["text-xs", muted_class()]}>{@obj.unit}</span>
        <.row_notes_badge count={@note_count} id={@obj.id} />
      </div>
      <div class="w-[11%] shrink-0 truncate">{@obj.category}</div>
      <div
        class="flex-1 min-w-0 truncate"
        title={"#{@obj.sales_account_name} · #{@obj.sales_tax_code_name}"}
      >
        {@obj.sales_account_name}
        <span class={muted_class()}>· {@obj.sales_tax_code_name}</span>
      </div>
      <div
        class="flex-1 min-w-0 truncate"
        title={"#{@obj.purchase_account_name} · #{@obj.purchase_tax_code_name}"}
      >
        {@obj.purchase_account_name}
        <span class={muted_class()}>· {@obj.purchase_tax_code_name}</span>
      </div>
      <% packs = @obj.packagings |> Enum.reject(&is_nil/1) |> Enum.map_join(", ", & &1.name) %>
      <div class={["w-[16%] shrink-0 truncate", muted_class()]} title={packs}>{packs}</div>
      <.link
        navigate={~p"/companies/#{@current_company}/goods/#{@obj.id}/copy"}
        class="w-14 shrink-0 text-xs text-center rounded-full border border-orange-400/70 px-2 py-0.5 text-orange-800 dark:text-orange-300 hover:bg-orange-100/60 dark:hover:bg-orange-950"
        tabindex="-1"
      >
        {gettext("Copy")}
      </.link>
    </div>
    """
  end
end
