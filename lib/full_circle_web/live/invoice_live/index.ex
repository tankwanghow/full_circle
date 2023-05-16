defmodule FullCircleWeb.InvoiceLive.Index do
  use FullCircleWeb, :live_view

  alias FullCircle.CustomerBilling.Invoice
  alias FullCircle.CustomerBilling
  alias FullCircle.StdInterface
  alias FullCircleWeb.InvoiceLive.FormComponent
  alias FullCircleWeb.InvoiceLive.IndexComponent

  @per_page 8

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-3xl">
      <p class="w-full text-3xl text-center font-medium"><%= @page_title %></p>
      <div class="flex justify-center mb-2">
        <.form for={%{}} id="search-form" phx-submit="search" autocomplete="off" class="w-full">
          <div class=" flex flex-row flex-wrap tracking-tighter text-sm">
            <div class="w-[25rem] grow shrink">
              <label class="">Search Terms</label>
              <.input
                id="search_terms"
                name="search[terms]"
                type="search"
                value={@search.terms}
                placeholder="invoice, contact, goods or descriptions..."
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
        <.link phx-click={:new_object} class={"#{button_css()} text-xl"} id="new_object">
          <%= gettext("New Invoice") %>
        </.link>
      </div>
      <div class="text-center mb-1">
        <div class="rounded bg-amber-200 border border-amber-500 font-bold p-2">
          <%= gettext("Invoice Information") %>
        </div>
      </div>
      <div :if={@objects_count > 0 or @update != "replace"} id="objects_list" phx-update={@update}>
        <%= for obj <- @objects do %>
          <.live_component
            module={IndexComponent}
            id={"objects-#{obj.id}"}
            obj={obj}
            company={@current_company}
            ex_class=""
          />
        <% end %>
      </div>
      <.infinite_scroll_footer page={@page} count={@objects_count} per_page={@per_page} />
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
    objects = filter_objects(socket, "", "", "", 1)

    socket =
      socket
      |> assign(page_title: gettext("Invoice Listing"))
      |> assign(page: 1, per_page: @per_page)
      |> assign(search: %{terms: "", invoice_date: "", due_date: ""})
      |> assign(update: "append")
      |> assign(objects_count: Enum.count(objects))
      |> assign(objects: objects)

    {:ok, socket, temporary_assigns: [objects: []]}
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
     |> assign(current_company: socket.assigns.current_company)
     |> assign(current_user: socket.assigns.current_user)
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
      CustomerBilling.get_invoice!(
        id,
        socket.assigns.current_user,
        socket.assigns.current_company
      )

    {:noreply,
     socket
     |> assign(live_action: :edit)
     |> assign(id: id)
     |> assign(title: gettext("Edit Invoice") <> " " <> object.invoice_no)
     |> assign(current_company: socket.assigns.current_company)
     |> assign(current_user: socket.assigns.current_user)
     |> assign(
       :form,
       to_form(StdInterface.changeset(Invoice, object, %{}, socket.assigns.current_company))
     )}
  end

  @impl true
  def handle_event("load-more", _, socket) do
    objects =
      filter_objects(
        socket,
        socket.assigns.search.terms,
        socket.assigns.search.invoice_date,
        socket.assigns.search.due_date,
        socket.assigns.page + 1
      )

    {:noreply,
     socket
     |> update(:page, &(&1 + 1))
     |> assign(update: "append")
     |> assign(objects: objects)
     |> assign(objects_count: Enum.count(objects))}
  end

  @impl true
  def handle_event(
        "search",
        %{"search" => %{"terms" => terms, "invoice_date" => id, "due_date" => dd}},
        socket
      ) do
    objects = filter_objects(socket, terms, id, dd, 1)

    socket =
      socket
      |> assign(page: 1, per_page: @per_page)
      |> assign(search: %{terms: terms, invoice_date: id, due_date: dd})
      |> assign(update: "replace")
      |> assign(:objects_count, Enum.count(objects))
      |> assign(:objects, objects)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:created, obj}, socket) do
    inv =
      FullCircle.CustomerBilling.get_invoice_by_id_index_component_field!(
        obj.id,
        socket.assigns.current_user,
        socket.assigns.current_company
      )

    css_trans(IndexComponent, inv, :obj, "objects-#{inv.id}", "shake")

    {:noreply,
     socket
     |> assign(update: "prepend")
     |> assign(live_action: nil)
     |> assign(objects: [inv | socket.assigns.objects])}
  end

  def handle_info({:updated, obj}, socket) do
    inv =
      FullCircle.CustomerBilling.get_invoice_by_id_index_component_field!(
        obj.id,
        socket.assigns.current_user,
        socket.assigns.current_company
      )

    css_trans(IndexComponent, inv, :obj, "objects-#{inv.id}", "shake")

    {:noreply, socket |> assign(live_action: nil)}
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

  defp filter_objects(socket, terms, invoice_date, due_date, page) do
    CustomerBilling.invoice_index_query(
      terms,
      invoice_date,
      due_date,
      socket.assigns.current_user,
      socket.assigns.current_company,
      page: page,
      per_page: @per_page
    )
  end
end
