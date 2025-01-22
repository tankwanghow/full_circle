defmodule FullCircleWeb.DeliveryLive.IndexComponent do
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
      class={"#{@ex_class} max-h-8 flex flex-row text-center tracking-tighter bg-gray-200 hover:bg-gray-400"}
    >
      <div class="w-[2%] border-b border-gray-400 py-1">
        <input
          :if={@obj.checked}
          id={"checkbox_#{@id}"}
          type="checkbox"
          class="rounded border-gray-400 checked:bg-gray-400"
          phx-click="check_click"
          phx-value-object-id={@id}
          checked
        />
        <input
          :if={!@obj.checked}
          id={"checkbox_#{@id}"}
          type="checkbox"
          class="rounded border-gray-400 checked:bg-gray-400"
          phx-click="check_click"
          phx-value-object-id={@id}
        />
      </div>
      <div class="w-[7%] border-b border-gray-400 py-1">
        {@obj.load_date |> FullCircleWeb.Helpers.format_date()}
      </div>
      <div class="w-[7%] border-b border-gray-400 py-1">
        <.doc_link
          current_company={@company}
          doc_obj={%{doc_type: "Load", doc_id: @obj.id, doc_no: @obj.load_no}}
        />
      </div>
      <div class="w-[15%] border-b border-gray-400 py-1 overflow-clip">
        {@obj.supplier_name}
      </div>
      <div class="w-[15%] border-b border-gray-400 py-1 overflow-clip">
        {@obj.shipper_name}
      </div>
      <div class="w-[8%] border-b border-gray-400 py-1 overflow-clip">
        {@obj.lorry}
      </div>
      <div class="w-[15%] border-b text-center border-gray-400 py-1 overflow-clip">
        <span class="font-light">
          {@obj.good_name}
        </span>
      </div>
      <div class="w-[15%] border-b border-gray-400 py-1">
        {@obj.load_pack_qty} {@obj.package}
      </div>
      <div class="w-[8%] border-b border-gray-400 py-1">
        {@obj.load_qty} {@obj.unit}
      </div>
      <div class="w-[8%] border-b border-gray-400 py-1">
        {@obj.status}
      </div>
    </div>
    """
  end
end
