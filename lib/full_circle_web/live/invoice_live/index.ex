defmodule FullCircleWeb.InvoiceLive.Index do
  use FullCircleWeb, :live_view

  alias FullCircle.Billing.Invoice
  alias FullCircle.Billing
  alias FullCircle.StdInterface
  alias FullCircleWeb.InvoiceLive.FormComponent
  alias FullCircleWeb.InvoiceLive.IndexComponent

  @per_page 25

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto w-12/12">
      <p class="w-full text-3xl text-center font-medium"><%= @page_title %></p>
      <div class="flex justify-center mb-2">
        <.form for={%{}} id="search-form" phx-submit="search" autocomplete="off" class="w-full">
          <div class=" flex flex-row flex-wrap tracking-tighter text-sm">
            <div class="w-[15.5rem] grow shrink">
              <label class="">Search Terms</label>
              <.input
                id="search_terms"
                name="search[terms]"
                type="search"
                value={@search.terms}
                placeholder="invoice, contact or particulars..."
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
              <label>Invocie Date From</label>
              <.input
                name="search[invoice_date]"
                type="date"
                value={@search.invoice_date}
                id="search_invoice_date"
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
        <.link phx-click={:new_object} class="link_button" id="new_object">
          <%= gettext("New Invoice") %>
        </.link>
        <.link
          :if={@ids != ""}
          navigate={
            ~p"/companies/#{@current_company.id}/invoices/print_multi?pre_print=false&ids=#{@ids}"
          }
          target="_blank"
          class="link_button"
        >
          <%= gettext("Print") %>
        </.link>
        <.link
          :if={@ids != ""}
          navigate={
            ~p"/companies/#{@current_company.id}/invoices/print_multi?pre_print=true&ids=#{@ids}"
          }
          target="_blank"
          class="link_button"
        >
          <%= gettext("Pre Print") %>
        </.link>
      </div>
      <div class="font-medium flex flex-row text-center tracking-tighter bg-amber-200">
        <div class="w-[2rem] border-b border-t border-amber-400 py-1"></div>
        <div class="w-[9rem] border-b border-t border-amber-400 py-1">
          <%= gettext("Date") %>
        </div>
        <div class="w-[9rem] border-b border-t border-amber-400 py-1">
          <%= gettext("Due Date") %>
        </div>
        <div class="w-[10rem] border-b border-t border-amber-400 py-1">
          <%= gettext("Invoice No") %>
        </div>
        <div class="w-[18.4rem] border-b border-t border-amber-400 py-1">
          <%= gettext("Contact") %>
        </div>
        <div class="w-[30rem] border-b border-t border-amber-400 py-1">
          <%= gettext("Particulars") %>
        </div>
        <div class="w-[9rem] border-b border-t border-amber-400 py-1">
          <%= gettext("Amount") %>
        </div>
        <div class="w-[9rem] border-b border-t border-amber-400 py-1">
          <%= gettext("Balance") %>
        </div>
        <div class="w-[3.6rem] border-b border-t border-amber-400 py-1">
          <%= gettext("action") %>
        </div>
      </div>
      <div
        :if={Enum.count(@streams.objects) > 0 or @page > 1}
        id="objects_list"
        phx-update={@update}
        phx-viewport-bottom={!@end_of_timeline? && "next-page"}
        phx-page-loading
      >
        <%= for {obj_id, obj} <- @streams.objects do %>
          <.live_component
            module={IndexComponent}
            id={obj_id}
            obj={obj}
            company={@current_company}
            ex_class=""
          />
        <% end %>
      </div>
      <.infinite_scroll_footer ended={@end_of_timeline?} />
    </div>

    <.modal
      :if={@live_action in [:new, :edit]}
      id="object-crud-modal"
      show
      max_w="max-w-full"
      on_cancel={JS.push("modal_cancel")}
    >
      <.live_component
        module={FormComponent}
        id={@id}
        title={@title}
        live_action={@live_action}
        form={@form}
        current_company={@current_company}
        current_user={@current_user}
      />
    </.modal>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(page_title: gettext("Invoice Listing"))
      |> assign(selected_invoices: [])
      |> assign(ids: "")
      |> filter_objects("", "stream", "", "", "", 1)

    {:ok, socket}
  end

  @impl true
  def handle_event("modal_cancel", _, socket) do
    {:noreply, socket |> assign(live_action: nil)}
  end

  @impl true
  def handle_event("new_object", _, socket) do
    {:noreply,
     socket
     |> assign(live_action: :new)
     |> assign(id: "new")
     |> assign(title: gettext("New Invoice"))
     |> assign(
       :form,
       to_form(
         StdInterface.changeset(
           Invoice,
           %Invoice{invoice_details: []},
           %{invoice_no: "...new..."},
           socket.assigns.current_company
         )
       )
     )}
  end

  @impl true
  def handle_event("edit_object", %{"object-id" => id}, socket) do
    object =
      Billing.get_invoice!(
        id,
        socket.assigns.current_company,
        socket.assigns.current_user
      )

    {:noreply,
     socket
     |> assign(live_action: :edit)
     |> assign(id: id)
     |> assign(title: gettext("Edit Invoice") <> " " <> object.invoice_no)
     |> assign(
       :form,
       to_form(StdInterface.changeset(Invoice, object, %{}, socket.assigns.current_company))
     )}
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
      |> assign(selected_invoices: [id | socket.assigns.selected_invoices])

    {:noreply, socket |> assign(ids: Enum.join(socket.assigns.selected_invoices, ","))}
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
      |> assign(
        selected_invoices: Enum.reject(socket.assigns.selected_invoices, fn sid -> sid == id end)
      )

    {:noreply, socket |> assign(ids: Enum.join(socket.assigns.selected_invoices, ","))}
  end

  @impl true
  def handle_event("next-page", _, socket) do
    {:noreply,
     socket
     |> filter_objects(
       socket.assigns.search.terms,
       "stream",
       socket.assigns.search.invoice_date,
       socket.assigns.search.due_date,
       socket.assigns.search.balance,
       socket.assigns.page + 1
     )}
  end

  @impl true
  def handle_event(
        "search",
        %{"search" => %{"terms" => terms, "invoice_date" => id, "due_date" => dd, "balance" => bal}},
        socket
      ) do
    {:noreply,
     socket
     |> filter_objects(terms, "replace", id, dd, bal, 1)}
  end

  @impl true
  def handle_info({:created, obj}, socket) do
    obj =
      FullCircle.Billing.get_invoice_by_id_index_component_field!(
        obj.id,
        socket.assigns.current_company,
        socket.assigns.current_user
      )

    css_trans(IndexComponent, obj, :obj, "objects-#{obj.id}", "shake")

    {:noreply,
     socket
     |> assign(live_action: nil)
     |> stream_insert(:objects, obj, at: 0)}
  end

  def handle_info({:updated, obj}, socket) do
    obj =
      FullCircle.Billing.get_invoice_by_id_index_component_field!(
        obj.id,
        socket.assigns.current_company,
        socket.assigns.current_user
      )

    socket =
      socket
      |> assign(
        selected_invoices:
          Enum.reject(socket.assigns.selected_invoices, fn sid -> sid == obj.id end)
      )

    css_trans(IndexComponent, obj, :obj, "objects-#{obj.id}", "shake")

    {:noreply,
     socket
     |> assign(live_action: nil)
     |> assign(ids: Enum.join(socket.assigns.selected_invoices, ","))}
  end

  def handle_info({:deleted, obj}, socket) do
    css_trans(IndexComponent, obj, :obj, "objects-#{obj.id}", "slow-hide", "hidden")

    {:noreply,
     socket
     |> assign(live_action: nil)}
  end

  @impl true
  def handle_info({:error, failed_operation, failed_value}, socket) do
    {:noreply,
     socket
     |> assign(live_action: nil)
     |> put_flash(
       :error,
       "#{gettext("Failed")} #{failed_operation}. #{list_errors_to_string(failed_value.errors)}"
     )}
  end

  @impl true
  def handle_info(:not_authorise, socket) do
    {:noreply,
     socket
     |> assign(live_action: nil)
     |> put_flash(:error, gettext("You are not authorised to perform this action"))}
  end

  @impl true
  def handle_info({:sql_error, msg}, socket) do
    {:noreply,
     socket
     |> assign(live_action: nil)
     |> put_flash(:error, msg)}
  end

  defp filter_objects(socket, terms, update, invoice_date, due_date, bal, page) do
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
    |> assign(search: %{terms: terms, balance: bal, invoice_date: invoice_date, due_date: due_date})
    |> assign(update: update)
    |> stream(:objects, objects, reset: obj_count == 0)
    |> assign(selected_invoices: [])
    |> assign(ids: "")
    |> assign(end_of_timeline?: obj_count < @per_page)
  end
end
