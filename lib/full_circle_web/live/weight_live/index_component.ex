defmodule FullCircleWeb.WeighingLive.IndexComponent do
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
    <div
      id={@id}
      class={[row_class(@ex_class), line_class("gap-0")]}
    >
      <div class="w-[10%] shrink-0 min-w-0 truncate px-1">
        {FullCircleWeb.Helpers.format_date(@obj.note_date)}
      </div>
      <div class="w-[10%] shrink-0 min-w-0 truncate px-1">
        <.doc_link
          current_company={@company}
          doc_obj={%{doc_type: "Weighing", doc_id: @obj.id, doc_no: @obj.note_no}}
        />
      </div>
      <div class="w-[10%] shrink-0 min-w-0 truncate px-1">
        {@obj.vehicle_no}
      </div>
      <div class="w-[15%] shrink-0 min-w-0 truncate px-1">
        {@obj.good_name}
      </div>
      <div class="w-[10%] shrink-0 min-w-0 truncate px-1 text-right tabular-nums">
        {@obj.gross |> Number.Delimit.number_to_delimited(precision: 0)}
      </div>
      <div class="w-[10%] shrink-0 min-w-0 truncate px-1 text-right tabular-nums">
        {@obj.tare |> Number.Delimit.number_to_delimited(precision: 0)}
      </div>
      <div class="w-[10%] shrink-0 min-w-0 truncate px-1 text-right tabular-nums">
        {(@obj.gross - @obj.tare) |> Number.Delimit.number_to_delimited(precision: 0)}
      </div>
      <div class="w-[5%] shrink-0 min-w-0 truncate px-1">
        {@obj.unit}
      </div>
      <div class="w-[20%] shrink-0 min-w-0 truncate px-1">
        {@obj.note}
      </div>
    </div>
    """
  end
end
