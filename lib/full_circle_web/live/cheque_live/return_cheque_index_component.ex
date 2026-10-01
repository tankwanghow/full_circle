defmodule FullCircleWeb.ChequeLive.ReturnChequeIndexComponent do
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
      <div class="w-[13%] shrink-0 min-w-0 truncate px-1">
        {@obj.doc_date |> FullCircleWeb.Helpers.format_date()}
      </div>

      <div
        :if={!@obj.old_data}
        class="text-blue-600 hover:font-bold w-[12%] border-b border-gray-400 py-1 hover:cursor-pointer"
      >
        <.link navigate={~p"/companies/#{@company.id}/ReturnCheque/#{@obj.return_id}/edit"}>
          {@obj.doc_no}
        </.link>
        <.row_notes_badge :if={@obj.return_id} count={@note_count} id={@obj.return_id} />
      </div>

      <div :if={@obj.old_data} class="w-[12%] shrink-0 min-w-0 truncate px-1">
        {@obj.doc_no}
      </div>

      <div class="w-[30%] shrink-0 min-w-0 truncate px-1">
        {@obj.cheque_owner_name}
      </div>

      <div class="w-[30%] shrink-0 min-w-0 truncate px-1">
        <span class={muted_class()}>{@obj.particulars}</span>
      </div>
      <div class="w-[15%] shrink-0 min-w-0 truncate px-1 text-right tabular-nums">
        {Number.Currency.number_to_currency(@obj.amount)}
      </div>
    </div>
    """
  end
end
