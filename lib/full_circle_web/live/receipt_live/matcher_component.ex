defmodule FullCircleWeb.ReceiptLive.MatcherComponent do
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
    <div id={@id} class={@klass}>
      <div class="flex flex-row flex-wrap font-medium text-center mt-2 tracking-tighter">
        <div class="detail-header w-[16%]"><%= gettext("Doc Date") %></div>
        <div class="detail-header w-[17%]"><%= gettext("Doc Type") %></div>
        <div class="detail-header w-[16%]"><%= gettext("Doc No") %></div>
        <div class="detail-header w-[16%]"><%= gettext("Amount") %></div>
        <div class="detail-header w-[16%]"><%= gettext("Balance") %></div>
        <div class="detail-header w-[16%]"><%= gettext("Match") %></div>
      </div>
      <.inputs_for :let={dtl} field={@form[:transaction_matchers]}>
        <div class={"flex flex-row flex-wrap #{if(dtl[:delete].value == true, do: "hidden", else: "")}"}>
          <.input type="hidden" field={dtl[:transaction_id]} />
          <.input type="hidden" field={dtl[:all_matched_amount]} />
          <.input type="hidden" field={dtl[:account_id]} />
          <.input type="hidden" field={dtl[:entity]} />
          <div class="w-[16%]"><.input readonly field={dtl[:doc_date]} /></div>
          <div class="w-[17%]"><.input readonly field={dtl[:doc_type]} /></div>
          <div class="w-[16%]"><.input readonly field={dtl[:doc_no]} /></div>
          <div class="w-[16%]"><.input readonly type="number" field={dtl[:amount]} /></div>
          <div class="w-[16%]">
            <.input readonly type="number" field={dtl[:balance]} />
          </div>
          <div class="w-[16%]">
            <.input type="number" phx-debounce="500" step="0.01" field={dtl[:match_amount]} />
          </div>
          <div class="w-[3%] mt-2.5 text-rose-500">
            <.link phx-click={:delete_match_tran} phx-value-index={dtl.index} tabindex="-1">
              <.icon name="hero-trash-solid" class="h-5 w-5" />
            </.link>
            <%= Phoenix.HTML.Form.hidden_input(dtl, :delete) %>
          </div>
        </div>
      </.inputs_for>
      <div class="flex flex-row flex-wrap">
        <div class="w-[81%] pt-2 pr-2 font-semibold text-right">Matched Total</div>
        <div class="w-[16%] font-semi bold">
          <.input
            type="number"
            tabindex="-1"
            readonly
            field={@form[:matched_amount]}
            value={Ecto.Changeset.fetch_field!(@form.source, :matched_amount)}
          />
        </div>
      </div>
    </div>
    """
  end
end
