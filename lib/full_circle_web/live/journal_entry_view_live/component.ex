defmodule FullCircleWeb.JournalEntryViewLive.Component do
  use FullCircleWeb, :live_component

  alias FullCircle.Accounting

  @impl true
  def mount(socket) do
    socket =
      if(!Map.has_key?(socket.assigns, :label), do: assign(socket, :label, gettext("Journal")))

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
    <div id={@id}>
      <.link phx-target={@myself} phx-click={:show_journal} class="blue_button block">
        <%= gettext("Journal") %>
      </.link>
      <.modal
        :if={@show_journal}
        id={"object-journal-modal-#{@id}"}
        show
        on_cancel={JS.push("hide_journal", target: "##{@id}")}
        max_w="max-w-6xl"
      >
        <div class="max-w-full text-black">
          <p class="w-full text-3xl text-center font-medium mb-3">
            <%= @page_title %>
          </p>
          <div class="font-medium flex flex-row text-center mt-2 tracking-tighter">
            <div class="w-[9%] border rounded bg-gray-100 border-gray-400 px-2 py-1">
              <%= gettext("Date") %>
            </div>
            <div class="w-[11%] border rounded bg-gray-100 border-gray-400 px-2 py-1">
              <%= gettext("Doc No") %>
            </div>
            <div class="w-[24%] border rounded bg-gray-100 border-gray-400 px-2 py-1">
              <%= gettext("Account") %>
            </div>
            <div class="w-[29%] border rounded bg-gray-100 border-gray-400 px-2 py-1">
              <%= gettext("Particulars") %>
            </div>
            <div class="w-[13.5%] border rounded bg-gray-100 border-gray-400 px-2 py-1">
              <%= gettext("Debit") %>
            </div>
            <div class="w-[13.5%] border rounded bg-gray-100 border-gray-400 px-2 py-1">
              <%= gettext("Credit") %>
            </div>
          </div>
          <div id="journal_list">
            <%= for obj <- @entries do %>
              <div class="flex flex-row text-center tracking-tighter">
                <div class="w-[9%] border rounded bg-blue-100 border-blue-400 text-center px-2 py-1">
                  <%= obj.doc_date %>
                </div>
                <div class="w-[11%] border rounded bg-blue-100 border-blue-400 text-center px-2 py-1">
                  <%= obj.doc_no %>
                </div>
                <div class="w-[24%] border rounded bg-blue-100 border-blue-400 text-center px-2 py-1">
                  <%= obj.account_name %>
                </div>
                <div class="w-[29%] border rounded bg-blue-100 border-blue-400 px-2 py-1">
                  <%= obj.particulars %>
                </div>
                <div class="w-[13.5%] border rounded bg-blue-100 border-blue-400 text-center px-2 py-1">
                  <%= if(Decimal.gt?(obj.amount, 0), do: obj.amount, else: 0)
                  |> Number.Delimit.number_to_delimited() %>
                </div>
                <div class="w-[13.5%] border rounded bg-blue-100 border-blue-400 text-center px-2 py-1">
                  <%= if(Decimal.gt?(obj.amount, 0), do: 0, else: Decimal.abs(obj.amount))
                  |> Number.Delimit.number_to_delimited() %>
                </div>
              </div>
            <% end %>
            <div class="flex flex-row text-center tracking-tighter font-semibold">
              <div class="w-[73%]"></div>
              <div class="w-[13.5%] border rounded bg-blue-100 border-blue-400 text-center px-2 py-1">
                <%= Enum.reduce(@entries, Decimal.new("0"), fn x, acc ->
                  Decimal.add(
                    acc,
                    if(Decimal.gt?(x.amount, 0), do: Decimal.abs(x.amount), else: Decimal.new("0"))
                  )
                end)
                |> Number.Delimit.number_to_delimited() %>
              </div>
              <div class="w-[13.5%] border rounded bg-blue-100 border-blue-400 text-center px-2 py-1">
                <%= Enum.reduce(@entries, Decimal.new("0"), fn x, acc ->
                  Decimal.add(
                    acc,
                    if(Decimal.gt?(x.amount, 0), do: Decimal.new("0"), else: Decimal.abs(x.amount))
                  )
                end)
                |> Number.Delimit.number_to_delimited() %>
              </div>
            </div>
          </div>
        </div>
      </.modal>
    </div>
    """
  end
end
