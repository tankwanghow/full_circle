defmodule FullCircleWeb.EInvListLive.IndexComponent do
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
    <div id={@id} class="text-nowrap flex flex-row bg-gray-200 hover:bg-gray-300">
      <div class="w-[16%] border-b border-amber-400 p-1">
        <a
          class="text-blue-600 hover:font-medium"
          target="_blank"
          href={~w(https://myinvois.hasil.gov.my/documents/#{@obj["uuid"]})}
        >
          <%= @obj["uuid"] %>
        </a>
        <div class="text-sm">
          <% {doc, url} =
            FullCircle.EInvMetas.get_internal_document(
              @obj["typeName"],
              @obj["direction"],
              @obj,
              @company.id
            ) %>
          <%= if doc do %>
            <%= if doc.e_inv_uuid do %>
              <%= "#{@obj["internalId"]}" %>
              <.link patch={"#{url}"} target="_blank" class="px-1 rounded-xl bg-blue-400">
                matched
              </.link>
            <% else %>
              <%= "#{@obj["internalId"]}" %>
              <.link patch={"#{url}"} target="_blank" class="px-1 rounded-xl bg-orange-400">
                try match
              </.link>
            <% end %>
          <% else %>
            <%= "#{@obj["internalId"]}" %>
            <.link patch={"#{url}"} target="_blank" class="px-1 rounded-xl bg-green-400">
              new
            </.link>
          <% end %>
        </div>
      </div>
      <div class="w-[16%] text-wrap border-b border-amber-400 p-1">
        <div>
          <span>
            <%= @obj["dateTimeReceived"]
            |> Timex.parse!("{RFC3339}")
            |> FullCircleWeb.Helpers.format_date() %>
          </span>
          <span class="text-green-600">
            <%= @obj["dateTimeIssued"]
            |> Timex.parse!("{RFC3339}")
            |> FullCircleWeb.Helpers.format_date() %>
          </span>
          <span class="text-red-500">
            <%= if !is_nil(@obj["rejectRequestDateTime"]) do
              @obj["rejectRequestDateTime"]
              |> Timex.parse!("{RFC3339}")
              |> FullCircleWeb.Helpers.format_date()
            end %>
          </span>
        </div>
      </div>
      <div class="w-[7%] border-b border-amber-400 p-1">
        <div><%= @obj["typeName"] %></div>
        <div class="text-sm"><%= @obj["typeVersionName"] %></div>
      </div>
      <div class="w-[9%] text-center border-b border-amber-400 p-1">
        <%= @obj["documentCurrency"] %> <%= @obj["totalNetAmount"]
        |> Number.Delimit.number_to_delimited() %>
      </div>
      <div class="w-[15%] border-b border-amber-400 p-1">
        <div class="overflow-hidden"><%= @obj["supplierName"] %></div>
        <div class="text-sm"><%= @obj["supplierTIN"] %></div>
      </div>
      <div class="w-[15%] border-b border-amber-400 p-1">
        <div class="overflow-hidden"><%= @obj["buyerName"] %></div>
        <div class="text-sm"><%= @obj["buyerTIN"] %></div>
      </div>
      <div class="w-[16%] border-b border-amber-400 p-1">
        <div><%= @obj["submissionUid"] %></div>
        <div class="text-sm"><%= @obj["submissionChannel"] %></div>
      </div>
      <div class="w-[6%] text-center border-b border-amber-400 p-1">
        <%= @obj["status"] %>
      </div>
    </div>
    """
  end
end
