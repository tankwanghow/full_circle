defmodule FullCircleWeb.ReceiptLive.QryMatcherComponent do
  use FullCircleWeb, :live_component

  @impl true
  def mount(socket) do
    {:ok, socket}
  end

  @impl true
  def update(assigns, socket) do
    {:ok, socket |> assign(assigns)}
  end

  defp found_in_matched_trans?(source, id) do
    Enum.any?(Ecto.Changeset.fetch_field!(source, :transaction_matchers), fn x ->
      x.transaction_id == id
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class={@klass}>
      <div
        id="query-match-trans"
        class="hidden w-8/12 mx-auto text-center border bg-teal-200 mt-2 p-3 rounded-lg border-teal-400"
      >
        <.form
          for={%{}}
          id="query-match-trans-form"
          phx-submit="get_trans"
          autocomplete="off"
          class="w-full"
        >
          Select Transactions from
          <input
            type="date"
            id="query_from"
            name="query[from]"
            value={@query.from}
            class="py-1 rounded-md border border-gray-300 bg-white shadow-sm focus:border-zinc-400 focus:ring-0"
          /> to
          <input
            type="date"
            id="query_to"
            name="query[to]"
            value={@query.to}
            class="py-1 rounded-md border border-gray-300 bg-white shadow-sm focus:border-zinc-400 focus:ring-0"
          />
          <.button disabled={is_nil(Ecto.Changeset.fetch_field!(@form.source, :contact_id))}>
            <%= gettext("Query") %>
          </.button>
        </.form>
        <div
          :if={Enum.count(@query_match_trans) == 0}
          class="mt-2 p-4 border rounded-lg border-orange-600 bg-orange-200 text-center"
        >
          <%= gettext("No Data!") %>
        </div>

        <div
          :if={Enum.count(@query_match_trans) > 0}
          class="flex flex-row flex-wrap font-medium text-center mt-2 tracking-tighter"
        >
          <div class="detail-header w-[13%]"><%= gettext("Doc Date") %></div>
          <div class="detail-header w-[13%]"><%= gettext("Doc Type") %></div>
          <div class="detail-header w-[14%]"><%= gettext("Doc No") %></div>
          <div class="detail-header w-[27%]"><%= gettext("Particulars") %></div>
          <div class="detail-header w-[15%]"><%= gettext("Amount") %></div>
          <div class="detail-header w-[15%]"><%= gettext("Balance") %></div>
          <div class="w-[3%]"></div>
        </div>
        <%= for obj <- @query_match_trans do %>
          <div class="flex flex-row flex-wrap">
            <div class="max-h-8 w-[13%] border rounded bg-blue-200 border-blue-400 px-2 py-1">
              <%= obj.doc_date %>
            </div>
            <div class="max-h-8 w-[13%] border rounded bg-blue-200 border-blue-400 px-2 py-1">
              <%= obj.doc_type %>
            </div>
            <div class="max-h-8 w-[14%] border rounded bg-blue-200 border-blue-400 px-2 py-1">
              <%= if obj.old_data do %>
                <%= obj.doc_no %>
              <% else %>
                <.link
                  class="text-blue-600 hover:font-bold"
                  navigate={
                      "/companies/#{@current_company.id}/#{obj.doc_type}/#{obj.doc_id}/edit"
                    }
                >
                  <%= obj.doc_no %>
                </.link>
              <% end %>
            </div>
            <div class="max-h-8 w-[27%] border rounded bg-blue-200 border-blue-400 px-2 py-1 overflow-clip">
              <%= obj.particulars %>
            </div>
            <div class="max-h-8 w-[15%] border rounded bg-blue-200 border-blue-400 px-2 py-1">
              <%= obj.amount |> Number.Delimit.number_to_delimited() %>
            </div>
            <div class="max-h-8 w-[15%] border rounded bg-blue-200 border-blue-400 px-2 py-1">
              <%= obj.balance |> Number.Delimit.number_to_delimited() %>
            </div>
            <div
              :if={
                !found_in_matched_trans?(@form.source, obj.transaction_id) and
                  Decimal.positive?(obj.balance) and obj.doc_no != @form.data.receipt_no
              }
              class="w-[3%] text-green-500 cursor-pointer"
            >
              <.link phx-click={:add_match_tran} phx-value-trans-id={obj.transaction_id} tabindex="-1">
                <.icon name="hero-plus-circle-solid" class="h-7 w-7" />
              </.link>
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end
end
