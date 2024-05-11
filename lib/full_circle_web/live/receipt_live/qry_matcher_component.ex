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
            <%= obj.t_doc_date |> FullCircleWeb.Helpers.format_date() %>
          </div>
          <div class="max-h-8 w-[13%] border rounded bg-blue-200 border-blue-400 px-2 py-1">
            <%= obj.t_doc_type %>
          </div>
          <div class="max-h-8 w-[14%] border rounded bg-blue-200 border-blue-400 px-2 py-1">
            <%= if obj.old_data do %>
              <%= obj.t_doc_no %>
            <% else %>
              <.doc_link
                target="_blank"
                current_company={@current_company}
                doc_obj={%{doc_id: obj.t_doc_id, doc_type: obj.t_doc_type, doc_no: obj.t_doc_no}}
              />
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
          <%!-- <div
            :if={
              @balance_ve == "+ve" and
                !found_in_matched_trans?(@form.source, obj.transaction_id) and
                #Decimal.positive?(obj.balance) and
                obj.t_doc_no != Map.fetch!(@form.data, @doc_no_field)
            }
            class="w-[3%] text-green-500 cursor-pointer"
          >
            <.link phx-click={:add_match_tran} phx-value-trans-id={obj.transaction_id} tabindex="-1">
              <.icon name="hero-plus-circle-solid" class="h-7 w-7" />
            </.link>
          </div> --%>
          <div
            :if={
              !Enum.any?(@cannot_match_doc_type, fn x -> x == obj.t_doc_type end) and
                !found_in_matched_trans?(@form.source, obj.transaction_id) and
                !Decimal.eq?(obj.balance, 0) and
                obj.t_doc_no != Map.fetch!(@form.data, @doc_no_field)
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
    """
  end
end
