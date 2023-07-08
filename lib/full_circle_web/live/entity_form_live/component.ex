defmodule FullCircleWeb.EntityFormLive.Component do
  use FullCircleWeb, :live_component

  alias FullCircle.{Sys, Billing, StdInterface}
  alias FullCircle.Billing.{Invoice, PurInvoice}

  @impl true
  def mount(socket) do
    {:ok, socket}
  end

  @impl true
  def update(assigns, socket) do
    IO.inspect(socket)
    socket = socket |> assign(assigns)
    {:ok, socket}
  end

  @impl true
  def handle_event("modal_cancel", _, socket) do
    {:noreply, socket |> assign(live_action: nil)}
  end

  @impl true
  def handle_event("show_form", %{"entity" => entity, "doc_no" => doc_no}, socket) do
    {:noreply,
     socket
     |> assign(:live_action, :edit)
     |> entity_form(entity, doc_no)}
  end

  def entity_form(socket, "invoices", doc_no) do
    object =
      Billing.get_invoice_by_invoice_no!(
        doc_no,
        socket.assigns.current_company,
        socket.assigns.current_user
      )

    socket
    |> assign(id: object.id)
    |> assign(title: gettext("Edit Invoice") <> " " <> object.invoice_no)
    |> assign(module: FullCircleWeb.InvoiceLive.FormComponent)
    |> assign(
      :form,
      to_form(StdInterface.changeset(Invoice, object, %{}, socket.assigns.current_company))
    )
  end

  def entity_form(socket, "pur_invoices", doc_no) do
    object =
      Billing.get_pur_invoice_by_pur_invoice_no!(
        doc_no,
        socket.assigns.current_company,
        socket.assigns.current_user
      )

    socket
    |> assign(id: object.id)
    |> assign(title: gettext("Edit Purchase Invoice") <> " " <> object.pur_invoice_no)
    |> assign(module: FullCircleWeb.PurInvoiceLive.FormComponent)
    |> assign(
      :form,
      to_form(StdInterface.changeset(PurInvoice, object, %{}, socket.assigns.current_company))
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <span id={@id}>
      <.link
        phx-target={@myself}
        phx-click={:show_form}
        phx-value-entity={@entity}
        phx-value-doc_no={@doc_no}
        class="text-blue-600 hover:font-bold"
      >
        <%= @doc_no %>
      </.link>

      <.modal
        :if={@live_action == :edit}
        id="object-crud-modal"
        show
        max_w="max-w-full"
        on_cancel={JS.push("modal_cancel", target: "##{@id}")}
      >
        <.live_component
          module={@module}
          id={@id}
          title={@title}
          live_action={@live_action}
          form={@form}
          current_company={@current_company}
          current_user={@current_user}
        />
      </.modal>
    </span>
    """
  end
end
