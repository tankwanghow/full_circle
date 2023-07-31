defmodule FullCircleWeb.EntityFormLive.Component do
  use FullCircleWeb, :live_component

  alias FullCircle.{Billing}
  # alias FullCircle.Billing.{Invoice, PurInvoice}

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
    entity_form(socket, entity, doc_no)
  end

  def entity_form(socket, "invoices", doc_no) do
    object =
      Billing.get_invoice_by_invoice_no!(
        doc_no,
        socket.assigns.current_company,
        socket.assigns.current_user
      )

    {:noreply,
     socket
     |> push_navigate(
       to: ~p"/companies/#{socket.assigns.current_company.id}/invoices/#{object.id}/edit"
     )}
  end

  def entity_form(socket, "pur_invoices", doc_no) do
    object =
      Billing.get_pur_invoice_by_pur_invoice_no!(
        doc_no,
        socket.assigns.current_company,
        socket.assigns.current_user
      )

    {:noreply,
     socket
     |> push_navigate(
       to: ~p"/companies/#{socket.assigns.current_company.id}/pur_invoices/#{object.id}/edit"
     )}
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
