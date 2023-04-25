defmodule FullCircleWeb.JournalEntryViewLive.Index do
  use FullCircleWeb, :live_view
  alias FullCircle.Accounting

  @impl true
  def mount(
        %{"doc_type" => doc_type, "doc_no" => doc_no, "back" => back},
        _session,
        socket
      ) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Journal Entries"))
     |> assign(:doc_type, doc_type)
     |> assign(:doc_no, doc_no)
     |> assign(:back, back)
     |> assign(
       :entries,
       Accounting.journal_entries(
         doc_type,
         doc_no,
         socket.assigns.current_company,
         socket.assigns.current_user
       )
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto">
      <p class="w-full text-3xl text-center font-medium mb-3">
        <%= @page_title %>
        <.link navigate={@back} class={"#{button_css()}"}><%= gettext("Back") %></.link>
      </p>
      <div id="objects_list">
        <div class="font-medium flex flex-row flex-wrap text-center mt-2 tracking-tighter">
          <div class="w-28 border rounded bg-gray-200 border-gray-400 px-2 py-1">
            <%= gettext("Doc No") %>
          </div>
          <div class="w-28 border rounded bg-gray-200 border-gray-400 px-2 py-1">
            <%= gettext("Account") %>
          </div>
          <div class="w-60 border rounded bg-gray-200 border-gray-400 px-2 py-1">
            <%= gettext("Particulars") %>
          </div>
          <div class="w-24 border rounded bg-gray-200 border-gray-400 px-2 py-1">
            <%= gettext("Debit") %>
          </div>
          <div class="w-24 border rounded bg-gray-200 border-gray-400 px-2 py-1">
            <%= gettext("Credit") %>
          </div>
        </div>
        <%= for obj <- @entries do %>
          <div class="flex flex-row flex-warp text-center tracking-tighter">
            <div class="w-28 border rounded bg-blue-200 border-blue-400 text-center px-2 py-1">
              <%= obj.doc_no %>
            </div>
            <div class="w-28 border rounded bg-blue-200 border-blue-400 text-center px-2 py-1">
              <%= obj.account_name %>
            </div>
            <div class="w-60 border rounded bg-blue-200 border-blue-400 px-2 py-1">
              <%= obj.particulars %>
            </div>
            <div class="w-24 border rounded bg-blue-200 border-blue-400 text-center px-2 py-1">
              <%= if(Decimal.gt?(obj.amount, 0), do: obj.amount, else: 0)
              |> Number.Delimit.number_to_delimited() %>
            </div>
            <div class="w-24 border rounded bg-blue-200 border-blue-400 text-center px-2 py-1">
              <%= if(Decimal.gt?(obj.amount, 0), do: 0, else: Decimal.abs(obj.amount))
              |> Number.Delimit.number_to_delimited() %>
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end
end
