defmodule FullCircleWeb.ChequeLive.DepositIndexComponent do
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
    <div
      id={@id}
      class={[row_class(@ex_class), line_class("gap-0")]}
    >
      <div class="w-[15%] shrink-0 min-w-0 truncate px-1">
        {@obj.deposit_date |> FullCircleWeb.Helpers.format_date()}
      </div>

      <div
        :if={!@obj.old_data}
        class="w-[15%] shrink-0 min-w-0 truncate px-1 text-blue-600 hover:font-bold"
      >
        <.link navigate={~p"/companies/#{@company.id}/Deposit/#{@obj.deposit_id}/edit"}>
          {@obj.deposit_no}
        </.link>
        <.row_notes_badge :if={@obj.deposit_id} count={@note_count} id={@obj.deposit_id} />
      </div>

      <div :if={@obj.old_data} class="w-[15%] shrink-0 min-w-0 truncate px-1">
        {@obj.deposit_no}
      </div>

      <div class="w-[28%] shrink-0 min-w-0 truncate px-1">
        {@obj.deposit_bank_name}
      </div>
      <div class="w-[27%] shrink-0 min-w-0 truncate px-1">
        <span class={muted_class()}>{@obj.particulars}</span>
      </div>
      <div class="w-[15%] shrink-0 min-w-0 truncate px-1 text-right tabular-nums">
        {Number.Currency.number_to_currency(@obj.amount)}
      </div>
    </div>
    """
  end
end
