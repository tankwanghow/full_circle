defmodule FullCircleWeb.InvoiceLive.IndexComponent do
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
    <div id={@id} class={"#{@ex_class} text-center mb-1 border-gray-500 border-2 rounded"}>
      <div class="grid grid-cols-12">
        <div class="col-span-4 p-2 bg-gray-200">
          <div class="text-xl font-medium"><%= @obj.invoice_no %></div>
          <div class="font-medium">
            <%= Number.Currency.number_to_currency(@obj.invoice_amount) %>
          </div>
          <div class="text-xs font-light"><%= to_fc_time_format(@obj.updated_at) %></div>

          <.print_button company={@company} entity="invoices" entity_id={@obj.id} />
          <.pre_print_button company={@company} entity="invoices" entity_id={@obj.id} />
          <.live_component
            module={FullCircleWeb.LogLive.Component}
            id={"log_#{@obj.id}"}
            show_log={false}
            entity="invoices"
            entity_id={@obj.id}
          />
          <.live_component
            module={FullCircleWeb.JournalEntryViewLive.Component}
            id={"journal_#{@obj.id}"}
            show_journal={false}
            doc_type="invoices"
            doc_no={@obj.invoice_no}
            company_id={@obj.company_id}
          />
        </div>
        <div
          class="col-span-8 bg-gray-100 p-2 hover:bg-gray-400 cursor-pointer"
          phx-value-object-id={@obj.id}
          phx-click={:edit_object}
        >
          <span class="font-medium text-sm"><%= gettext("Invoice Date") %>:</span>
          <span class="text-sm"><%= @obj.invoice_date %></span>
          <span class="font-medium text-sm"><%= gettext("Due Date") %>:</span>
          <span class="text-sm"><%= @obj.due_date %></span>
          <div class="text-xl font-medium"><%= @obj.contact_name %></div>
          <p class="text-sm font-light"><%= @obj.goods %></p>
          <p><%= @obj.tags %></p>
          <p class="text-sm font-light"><%= @obj.descriptions %></p>
        </div>
      </div>
    </div>
    """
  end
end
