defmodule FullCircleWeb.EInvListLive.IndexReceivedComponent do
  use FullCircleWeb, :live_component

  @impl true
  def mount(socket) do
    {:ok, socket}
  end

  @impl true
  def update(assigns, socket) do
    fc_inv =
      FullCircle.EInvMetas.get_internal_document(
        "PurInvoice",
        "Received",
        assigns.obj,
        assigns.company,
        assigns.user
      )

    {:ok, socket |> assign(assigns) |> assign(fc_inv: fc_inv)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class="flex flex-row">
      <div class="w-[50%] text-nowrap flex flex-row bg-gray-200 hover:bg-gray-300 border-b border-amber-400 p-1">
        <div class="w-[22%] text-wrap  p-1">
          <div>
            <div class="">
              {@obj.dateTimeReceived
              |> FullCircleWeb.Helpers.format_datetime(@company)}
            </div>
            <div>
              {@obj.dateTimeIssued
              |> FullCircleWeb.Helpers.format_datetime(@company)}
            </div>
            <div>
              {if !is_nil(@obj.rejectRequestDateTime) do
                @obj.rejectRequestDateTime
                |> FullCircleWeb.Helpers.format_datetime(@company)
              end}
            </div>
          </div>
        </div>
        <div class="w-[36%]">
          <a
            class="text-blue-600 hover:font-medium"
            target="_blank"
            href={~w(https://myinvois.hasil.gov.my/documents/#{@obj.uuid})}
          >
            {@obj.uuid}
          </a>
          <div class="text-xs">
            {"#{@obj.internalId}"}
            <span class="font-bold text-orange-600">Received</span>
            <span class="text-purple-600">{@obj.typeName} {@obj.typeVersionName}</span>
          </div>
        </div>
        <div class="w-[42%]">
          <div class="overflow-hidden">{@obj.supplierName}</div>
          <div class="text-sm">
            {@obj.supplierTIN}
            <span class="font-bold">
              {@obj.documentCurrency}{@obj.totalNetAmount
              |> Number.Delimit.number_to_delimited()}
            </span>
            <span :if={@obj.status == "Valid"} class="text-green-600">{@obj.status}</span>
            <span :if={@obj.status == "Invalid"} class="text-rose-600">{@obj.status}</span>
            <span :if={@obj.status == "Canceled"} class="text-orange-600">{@obj.status}</span>
          </div>
        </div>
      </div>
      <div class="w-[50%] text-nowrap flex flex-row bg-gray-200 hover:bg-gray-300 border-b border-amber-400 p-1">
      </div>
    </div>
    """
  end
end
