defmodule FullCircleWeb.JournalEntryViewLive.Component do
  use FullCircleWeb, :live_component

  alias FullCircle.Accounting

  @impl true
  def mount(socket) do
    {
      :ok,
      socket
      |> assign(:page_title, gettext("Journal Entries"))
    }
  end

  @impl true
  def update(assigns, socket) do
    socket = socket |> assign(assigns)
    {:ok, socket}
  end

  @impl true
  def handle_event("show_journal", _, socket) do
    {:noreply,
     socket
     |> assign(:show_journal, true)
     |> assign(
       :entries,
       Accounting.journal_entries(
         socket.assigns.doc_type,
         socket.assigns.doc_no,
         socket.assigns.company_id
       )
     )}
  end

  @impl true
  def handle_event("hide_journal", _, socket) do
    {:noreply,
     socket
     |> assign(:show_journal, false)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <span id={@id}>
      <.link
        phx-target={@myself}
        phx-click={:show_journal}
        class="text-xs border rounded-full bg-pink-100 hover:bg-pink-400 px-2 py-1 border-pink-400"
      >
        <%= gettext("Journal") %>
      </.link>
      <.modal
        :if={@show_journal}
        id={"object-journal-modal-#{@id}"}
        show
        on_cancel={JS.push("hide_journal", target: "##{@id}")}
        max_w="max-w-6xl"
      >
        <div class="max-w-full">
          <p class="w-full text-3xl text-center font-medium mb-3">
            <%= @page_title %>
          </p>
          <div class="font-medium flex flex-row text-center mt-2 tracking-tighter">
            <div class="w-40 border rounded bg-gray-200 border-gray-400 px-2 py-1">
              <%= gettext("Doc No") %>
            </div>
            <div class="w-60 border rounded bg-gray-200 border-gray-400 px-2 py-1">
              <%= gettext("Account") %>
            </div>
            <div class="w-96 border rounded bg-gray-200 border-gray-400 px-2 py-1">
              <%= gettext("Particulars") %>
            </div>
            <div class="w-40 border rounded bg-gray-200 border-gray-400 px-2 py-1">
              <%= gettext("Debit") %>
            </div>
            <div class="w-40 border rounded bg-gray-200 border-gray-400 px-2 py-1">
              <%= gettext("Credit") %>
            </div>
          </div>
          <div id="journal_list">
            <%= for obj <- @entries do %>
              <div class="flex flex-row text-center tracking-tighter">
                <div class="w-40 border rounded bg-blue-200 border-blue-400 text-center px-2 py-1">
                  <%= obj.doc_no %>
                </div>
                <div class="w-60 border rounded bg-blue-200 border-blue-400 text-center px-2 py-1">
                  <%= obj.account_name %>
                </div>
                <div class="w-96 border rounded bg-blue-200 border-blue-400 px-2 py-1">
                  <%= obj.particulars %>
                </div>
                <div class="w-40 border rounded bg-blue-200 border-blue-400 text-center px-2 py-1">
                  <%= if(Decimal.gt?(obj.amount, 0), do: obj.amount, else: 0)
                  |> Number.Delimit.number_to_delimited() %>
                </div>
                <div class="w-40 border rounded bg-blue-200 border-blue-400 text-center px-2 py-1">
                  <%= if(Decimal.gt?(obj.amount, 0), do: 0, else: Decimal.abs(obj.amount))
                  |> Number.Delimit.number_to_delimited() %>
                </div>
              </div>
            <% end %>
          </div>
        </div>
      </.modal>
    </span>
    """
  end
end