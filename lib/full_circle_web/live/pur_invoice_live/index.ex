defmodule FullCircleWeb.PurInvoiceLive.Index do
  use FullCircleWeb, :live_view

  import FullCircleWeb.ListComponents

  alias FullCircle.Billing
  alias FullCircleWeb.PurInvoiceLive.IndexComponent
  alias FullCircleWeb.NoteLive.NotesIndex

  @per_page 25

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto w-11/12 max-w-[96rem]">
      <.form for={%{}} id="search-form" phx-submit="search" autocomplete="off">
        <.list_bar title={@page_title}>
          <div class="grow min-w-56">
            <.filter_label>{gettext("Search Terms")}</.filter_label>
            <.input
              id="search_terms"
              name="search[terms]"
              type="search"
              value={@search.terms}
              placeholder="pur_invoice, e_inv_internal_id, contact, goods or descriptions..."
            />
          </div>
          <div class="w-28">
            <.filter_label>{gettext("Balance")}</.filter_label>
            <.input
              name="search[balance]"
              type="select"
              options={~w(All Paid Unpaid)}
              value={@search.balance}
              id="search_balance"
            />
          </div>
          <div class="w-36">
            <.filter_label>{gettext("PurInvoice Date From")}</.filter_label>
            <.input
              name="search[pur_invoice_date]"
              type="date"
              value={@search.pur_invoice_date}
              id="search_pur_invoice_date"
            />
          </div>
          <div class="w-36">
            <.filter_label>{gettext("Due Date From")}</.filter_label>
            <.input
              name="search[due_date]"
              type="date"
              value={@search.due_date}
              id="search_due_date"
            />
          </div>
          <.button class="h-9 w-10">🔍</.button>
          <:actions>
            <.link
              navigate={~p"/companies/#{@current_company.id}/PurInvoice/new"}
              class="blue button"
              id="new_purinvoice"
            >
              + {gettext("New Purchase Invoice")}
            </.link>
          </:actions>
        </.list_bar>
      </.form>

      <.list_table>
        <:head>
          <div class="w-6 shrink-0"></div>
          <div class="w-24 shrink-0">{gettext("Date")}</div>
          <div class="w-56 shrink-0">{gettext("No.")}</div>
          <div class="flex-1 min-w-0">{gettext("Contact")}</div>
          <div class="w-[24%] shrink-0">{gettext("Particulars")}</div>
          <div class="w-28 shrink-0 text-right">{gettext("Amount")}</div>
          <div class="w-28 shrink-0 text-right">{gettext("Balance")}</div>
          <div class="w-16 shrink-0 text-right">{gettext("Overdue")}</div>
          <div class="w-36 shrink-0">{gettext("e-Invoice")}</div>
          <div class="w-6 shrink-0"></div>
        </:head>
        <div
          id="objects_list"
          phx-update="stream"
          phx-page-loading
        >
          <%= for {obj_id, obj} <- @streams.objects do %>
            <.live_component
              module={IndexComponent}
              note_count={Map.get(@note_counts, obj.id, 0)}
              task_count={Map.get(@task_counts, obj.id, 0)}
              id={obj_id}
              obj={obj}
              company={@current_company}
              user={@current_user}
              einv_portal={@einv_portal}
              ex_class=""
            />
          <% end %>
        </div>
      </.list_table>
      <.infinite_scroll_footer ended={@end_of_timeline?} />
      <NotesIndex.modal
        notes_for={@notes_for}
        notes_type={@notes_type}
        current_company={@current_company}
        current_user={@current_user}
      />
    </div>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(page_title: gettext("Purchase Invoice Listing"))
      |> NotesIndex.init("PurInvoice", IndexComponent)

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
    |> NotesIndex.count(objects, reset)
    |> stream(:objects, objects, reset: reset)
    |> assign(end_of_timeline?: obj_count < @per_page)
  end
end
