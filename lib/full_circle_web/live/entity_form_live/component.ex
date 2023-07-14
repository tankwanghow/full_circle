defmodule FullCircleWeb.EntityFormLive.Component do
  use FullCircleWeb, :live_component

  alias FullCircle.{Billing, StdInterface}
  alias FullCircle.Billing.{Invoice, PurInvoice}

  @impl true
  def mount(socket) do
    {:ok, socket}
  end

  @impl true
  def update(assigns, socket) do
    socket = socket |> assign(assigns)
    {:ok, socket}
  end

  @impl true
  def handle_event("show_form", %{"entity" => entity, "doc_no" => doc_no}, socket) do
    send(self(), {:show_form, entity_form(socket, entity, doc_no)})
    {:noreply, socket}
  end

  def entity_form(socket, "invoices", doc_no) do
    object =
      Billing.get_invoice_by_invoice_no!(
        doc_no,
        socket.assigns.current_company,
        socket.assigns.current_user
      )

    %{
      id: object.id,
      title: gettext("Edit Invoice") <> " " <> object.invoice_no,
      module: FullCircleWeb.InvoiceLive.FormComponent,
      form: to_form(StdInterface.changeset(Invoice, object, %{}, socket.assigns.current_company))
    }
  end

  def entity_form(socket, "pur_invoices", doc_no) do
    object =
      Billing.get_pur_invoice_by_pur_invoice_no!(
        doc_no,
        socket.assigns.current_company,
        socket.assigns.current_user
      )

    %{
      id: object.id,
      title: gettext("Edit Purchase Invoice") <> " " <> object.pur_invoice_no,
      module: FullCircleWeb.PurInvoiceLive.FormComponent,
      form:
        to_form(StdInterface.changeset(PurInvoice, object, %{}, socket.assigns.current_company))
    }
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
    </span>
    """
  end
end
