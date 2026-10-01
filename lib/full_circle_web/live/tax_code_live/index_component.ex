defmodule FullCircleWeb.TaxCodeLive.IndexComponent do
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
    <div id={@id} class={[row_class(@ex_class), line_class()]}>
      <div class="w-[16%] shrink-0 min-w-0 truncate">
        <.link
          :if={!FullCircle.Accounting.is_default_tax_code?(@obj)}
          class="hover:font-bold text-blue-600"
          navigate={~p"/companies/#{@current_company.id}/tax_codes/#{@obj.id}/edit"}
        >
          {@obj.code}
        </.link>
        <span :if={FullCircle.Accounting.is_default_tax_code?(@obj)} class="font-bold text-rose-600">
          {@obj.code}
        </span>
      </div>
      <div class="w-[12%] shrink-0 truncate">{@obj.tax_type}</div>
      <div class="w-20 shrink-0 text-right tabular-nums">
        {@obj.rate |> Decimal.mult(100) |> Number.Percentage.number_to_percentage()}
      </div>
      <div class="w-[24%] shrink-0 truncate" title={@obj.account_name}>{@obj.account_name}</div>
      <div class={["flex-1 min-w-0 truncate", muted_class()]} title={@obj.descriptions}>
        {@obj.descriptions}
      </div>
    </div>
    """
  end
end
