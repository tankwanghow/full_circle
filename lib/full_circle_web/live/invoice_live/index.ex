defmodule FullCircleWeb.InvoiceLive.Index do
  use FullCircleWeb, :live_view

  alias FullCircle.Billing
  alias FullCircleWeb.InvoiceLive.IndexComponent
  alias FullCircleWeb.NoteLive.NotesIndex

  @per_page 15
  @selected_max 15

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto w-11/12 max-w-[96rem]">
      <%!-- One bar: title · filters · actions --%>
      <.form
        for={%{}}
        id="search-form"
        phx-submit="search"
        autocomplete="off"
        class="flex flex-wrap items-end gap-2 mb-3 text-sm"
      >
        <h1 class="text-2xl font-medium mr-3 self-center">{@page_title}</h1>
        <div class="grow min-w-56">
          <label class="text-xs text-slate-500">{gettext("Search")}</label>
          <.input
            id="search_terms"
            name="search[terms]"
            type="search"
            value={@search.terms}
            placeholder={gettext("invoice no, contact or particulars…")}
          />
        </div>
        <div class="w-28">
          <label class="text-xs text-slate-500">{gettext("Balance")}</label>
          <.input
            name="search[balance]"
            type="select"
            options={~w(All Paid Unpaid)}
            value={@search.balance}
            id="search_balance"
          />
        </div>
        <div class="w-36">
          <label class="text-xs text-slate-500">{gettext("Invoice date from")}</label>
          <.input
            name="search[invoice_date]"
            type="date"
            value={@search.invoice_date}
            id="search_invoice_date"
          />
        </div>
        <div class="w-36">
          <label class="text-xs text-slate-500">{gettext("Due date from")}</label>
          <.input
            name="search[due_date]"
            type="date"
            value={@search.due_date}
            id="search_due_date"
          />
        </div>
        <.button class="h-9 w-10">🔍</.button>
        <div class="flex gap-1 ml-auto">
          <.link
            :if={@can_print}
            navigate={
              ~p"/companies/#{@current_company.id}/Invoice/print_multi?pre_print=false&ids=#{@ids}"
            }
            target="_blank"
            class="blue button"
          >
            {gettext("Print")}{"(#{Enum.count(@selected)})"}
          </.link>
          <.link
            :if={@can_print}
            navigate={
              ~p"/companies/#{@current_company.id}/Invoice/print_multi?pre_print=true&ids=#{@ids}"
            }
            target="_blank"
            class="blue button"
          >
            {gettext("Pre Print")}{"(#{Enum.count(@selected)})"}
          </.link>
          <.link
            navigate={~p"/companies/#{@current_company.id}/Invoice/new"}
            class="blue button"
            id="new_invoice"
          >
            + {gettext("New Invoice")}
          </.link>
        </div>
      </.form>

      <div class="rounded border border-slate-300 dark:border-gray-700 overflow-hidden">
        <div class="flex items-center gap-2 px-2 py-1.5 bg-slate-200 dark:bg-gray-800 text-xs font-semibold uppercase tracking-wide text-slate-600 dark:text-slate-300">
          <div class="w-6 shrink-0"></div>
          <div class="w-24 shrink-0">{gettext("Date")}</div>
          <div class="w-40 shrink-0">{gettext("No.")}</div>
          <div class="flex-1 min-w-0">{gettext("Contact")}</div>
          <div class="w-[24%] shrink-0">{gettext("Particulars")}</div>
          <div class="w-28 shrink-0 text-right">{gettext("Amount")}</div>
          <div class="w-28 shrink-0 text-right">{gettext("Balance")}</div>
          <div class="w-16 shrink-0 text-right">{gettext("Overdue")}</div>
          <div class="w-36 shrink-0">{gettext("e-Invoice")}</div>
          <div class="w-6 shrink-0"></div>
        </div>
        <div
          id="objects_list"
          phx-update="stream"
          phx-page-loading
        >
          <%= for {obj_id, obj} <- @streams.objects do %>
            <.live_component
              module={IndexComponent}
              note_count={Map.get(@note_counts, obj.id, 0)}
              id={obj_id}
              obj={obj}
              company={@current_company}
              user={@current_user}
              einv_portal={@einv_portal}
              ex_class=""
            />
          <% end %>
        </div>
      </div>
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
      |> assign(page_title: gettext("Invoice Listing"))
      |> NotesIndex.init("Invoice", IndexComponent)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    params = params["search"]

    terms = params["terms"] || ""
    bal = params["balance"] || ""
    invoice_date = params["invoice_date"] || ""
    due_date = params["due_date"] || ""

    {:noreply,
     socket
     |> assign(
       search: %{terms: terms, balance: bal, invoice_date: invoice_date, due_date: due_date}
     )
     |> assign(selected: [])
     |> assign(ids: "")
     |> assign(can_print: false)
     |> filter_objects(terms, true, invoice_date, due_date, bal, 1)}
  end

  @impl true
  def handle_event("check_click", %{"object-id" => id, "value" => "on"}, socket) do
    obj =
      FullCircle.Billing.get_invoice_by_id_index_component_field!(
        id,
        socket.assigns.current_company,
        socket.assigns.current_user
      )

    Phoenix.LiveView.send_update(
      self(),
      IndexComponent,
      [{:id, "objects-#{id}"}, {:obj, Map.merge(obj, %{checked: true})}]
    )

    socket =
      socket
      |> assign(selected: [id | socket.assigns.selected])
      |> FullCircleWeb.Helpers.can_print?(:selected, @selected_max)

    {:noreply, socket |> assign(ids: Enum.join(socket.assigns.selected, ","))}
  end

  @impl true
  def handle_event("check_click", %{"object-id" => id}, socket) do
    obj =
      FullCircle.Billing.get_invoice_by_id_index_component_field!(
        id,
        socket.assigns.current_company,
        socket.assigns.current_user
      )

    Phoenix.LiveView.send_update(
      self(),
      IndexComponent,
      [{:id, "objects-#{id}"}, {:obj, Map.merge(obj, %{checked: false})}]
    )

    socket =
      socket
      |> assign(selected: Enum.reject(socket.assigns.selected, fn sid -> sid == id end))
      |> FullCircleWeb.Helpers.can_print?(:selected, @selected_max)

    {:noreply, socket |> assign(ids: Enum.join(socket.assigns.selected, ","))}
  end

  @impl true
  def handle_event("next-page", _, socket) do
    {:noreply,
     socket
     |> filter_objects(
       socket.assigns.search.terms,
       false,
       socket.assigns.search.invoice_date,
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
            "invoice_date" => id,
            "due_date" => dd,
            "balance" => bal
          }
        },
        socket
      ) do
    qry = %{
      "search[terms]" => terms,
      "search[balance]" => bal,
      "search[invoice_date]" => id,
      "search[due_date]" => dd
    }

    url = "/companies/#{socket.assigns.current_company.id}/Invoice?#{URI.encode_query(qry)}"

    {:noreply, socket |> push_navigate(to: url)}
  end

  defp filter_objects(socket, terms, reset, invoice_date, due_date, bal, page) do
    objects =
      Billing.invoice_index_query(
        terms,
        invoice_date,
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
