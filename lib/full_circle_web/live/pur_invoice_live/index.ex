defmodule FullCircleWeb.PurInvoiceLive.Index do
  use FullCircleWeb, :live_view

  alias FullCircle.Billing
  alias FullCircleWeb.PurInvoiceLive.IndexComponent

  @per_page 25

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto w-11/12">
      <p class="w-full text-3xl text-center font-medium">{@page_title}</p>
      <div class="flex justify-center mb-2">
        <.form for={%{}} id="search-form" phx-submit="search" class="w-full" autocomplete="off">
          <div class=" flex flex-row flex-wrap tracking-tighter text-sm">
            <div class="w-[25rem] grow shrink">
              <label class="">Search Terms</label>
              <.input
                id="search_terms"
                name="search[terms]"
                type="search"
                value={@search.terms}
                placeholder="pur_invoice, e_inv_internal_id, contact, goods or descriptions..."
              />
            </div>
            <div class="w-[7rem] grow-0 shrink-0">
              <label>Balance</label>
              <.input
                name="search[balance]"
                type="select"
                options={~w(All Paid Unpaid)}
                value={@search.balance}
                id="search_balance"
              />
            </div>
            <div class="w-[9.5rem] grow-0 shrink-0">
              <label>PurInvoice Date From</label>
              <.input
                name="search[pur_invoice_date]"
                type="date"
                value={@search.pur_invoice_date}
                id="search_pur_invoice_date"
              />
            </div>
            <div class="w-[9.5rem] grow-0 shrink-0">
              <label>Due Date From</label>
              <.input
                name="search[due_date]"
                type="date"
                value={@search.due_date}
                id="search_due_date"
              />
            </div>
            <.button class="mt-5 h-10 w-10 grow-0 shrink-0">🔍</.button>
          </div>
        </.form>
      </div>
      <div class="text-center mb-2">
        <.link
          navigate={~p"/companies/#{@current_company.id}/PurInvoice/new"}
          class="blue button"
          id="new_purinvoice"
        >
          {gettext("New Purchase Invoice")}
        </.link>
      </div>

      <div class="font-medium flex flex-row text-center tracking-tighter bg-amber-200">
        <div class="w-[6%] border-b border-t border-amber-400 py-1">
          <div>{gettext("Invoice Date")}</div>
          <div>{gettext("Due Date")}</div>
        </div>
        <div class="w-[18%] border-b border-t border-amber-400 py-1">
          {gettext("Contact / InternalId / PurInvoiceNo / TIN / RegNo")}
        </div>
        <div class="w-[18%] border-b border-t border-amber-400 py-1">
          {gettext("Particulars")}
        </div>
        <div class="w-[7%] border-b border-t border-amber-400 py-1">
          {gettext("Amount / Balance")}
        </div>
        <div class="w-[0.4%] bg-white"></div>
        <div class="font-medium flex flex-row bg-blue-200 w-[50.6%]">
          <div class="w-[22%] border-b border-t border-blue-400 p-1">
            <div>{gettext("Received/ Issued/ Reject")}</div>
          </div>
          <div class="w-[36%] border-b border-t border-blue-400 p-1">
            <div>{gettext("UUD/ InternalId/ Direction/ Type/ Version")}</div>
          </div>
          <div class="w-[42%] border-b border-t border-blue-400 p-1">
            <div>{gettext("ContactName/ TIN/ Amount")}</div>
          </div>
        </div>
      </div>
      <div
        :if={Enum.count(@streams.objects) > 0 or @page > 1}
        id="objects_list"
        phx-update="stream"
        phx-viewport-bottom={!@end_of_timeline? && "next-page"}
        phx-page-loading
      >
        <%= for {obj_id, obj} <- @streams.objects do %>
          <.live_component
            module={IndexComponent}
            id={obj_id}
            obj={obj}
            company={@current_company}
            user={@current_user}
            ex_class=""
          />
        <% end %>
      </div>
      <.infinite_scroll_footer ended={@end_of_timeline?} />
    </div>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(page_title: gettext("Purchase Invoice Listing"))

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    params = params["search"]

    terms = params["terms"] || ""
    bal = params["balance"] || ""
    pur_invoice_date = params["pur_invoice_date"] || ""
    due_date = params["due_date"] || ""

    {:noreply,
     socket
     |> assign(
       search: %{
         terms: terms,
         balance: bal,
         pur_invoice_date: pur_invoice_date,
         due_date: due_date
       }
     )
     |> filter_objects(terms, true, pur_invoice_date, due_date, bal, 1)}
  end

  @impl true
  def handle_event("next-page", _, socket) do
    {:noreply,
     socket
     |> filter_objects(
       socket.assigns.search.terms,
       false,
       socket.assigns.search.pur_invoice_date,
       socket.assigns.search.due_date,
       socket.assigns.search.balance,
       socket.assigns.page + 1
     )}
  end

  @impl true
  def handle_event(
        "search",
        %{
          "search" => %{
            "terms" => terms,
            "pur_invoice_date" => id,
            "due_date" => dd,
            "balance" => bal
          }
        },
        socket
      ) do
    qry = %{
      "search[terms]" => terms,
      "search[balance]" => bal,
      "search[pur_invoice_date]" => id,
      "search[due_date]" => dd
    }

    url = "/companies/#{socket.assigns.current_company.id}/PurInvoice?#{URI.encode_query(qry)}"

    {:noreply, socket |> push_navigate(to: url)}
  end

  defp filter_objects(socket, terms, reset, pur_invoice_date, due_date, bal, page) do
    objects =
      Billing.pur_invoice_index_query(
        terms,
        pur_invoice_date,
        due_date,
        bal,
        socket.assigns.current_company,
        socket.assigns.current_user,
        page: page,
        per_page: @per_page
      )

    obj_count = Enum.count(objects)

    socket
    |> assign(page: page, per_page: @per_page)
    |> stream(:objects, objects, reset: reset)
    |> assign(end_of_timeline?: obj_count < @per_page)
  end
end
