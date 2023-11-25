defmodule FullCircleWeb.WeighingLive.IndexComponent do
  use FullCircleWeb, :live_component

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
      class={"#{@ex_class} max-h-8 font-mono flex flex-row text-center tracking-tighter bg-gray-200 hover:bg-gray-400"}
    >
      <div class="w-[10%] border-b border-gray-400 py-1">
        <%= FullCircleWeb.Helpers.format_date(@obj.note_date) %>
      </div>
      <div class="w-[10%] border-b border-gray-400 py-1">
        <.doc_link
          current_company={@company}
          doc_obj={%{doc_type: "Weighing", doc_id: @obj.id, doc_no: @obj.note_no}}
        />
      </div>
      <div class="w-[10%] border-b text-center border-gray-400 py-1 overflow-clip">
        <%= @obj.vehicle_no %>
      </div>
      <div class="w-[15%] border-b text-center border-gray-400 py-1 overflow-clip">
        <%= @obj.good_name %>
      </div>
      <div class="w-[10%] border-b border-gray-400 py-1 text-right pr-2">
        <%= @obj.gross |> Number.Delimit.number_to_delimited(precision: 0) %>
      </div>
      <div class="w-[10%] border-b border-gray-400 py-1 text-right pr-2">
        <%= @obj.tare |> Number.Delimit.number_to_delimited(precision: 0) %>
      </div>
      <div class="w-[10%] border-b border-gray-400 py-1 text-right pr-2">
        <%= (@obj.gross - @obj.tare) |> Number.Delimit.number_to_delimited(precision: 0) %>
      </div>
      <div class="w-[5%] border-b border-gray-400 py-1 pr-2">
        <%= @obj.unit %>
      </div>
      <div class="w-[20%] border-b text-center border-gray-400 py-1 overflow-clip">
        <%= @obj.note %>
      </div>
    </div>
    """
  end
end
