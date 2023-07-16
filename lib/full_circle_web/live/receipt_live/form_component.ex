defmodule FullCircleWeb.ReceiptLive.FormComponent do
  use FullCircleWeb, :live_component

  alias FullCircle.ReceiveFunds

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.header>
        <%= @title %>
        <:subtitle>Use this form to manage receipt records in your database.</:subtitle>
      </.header>

      <.simple_form
        for={@form}
        id="receipt-form"
        phx-target={@myself}
        phx-change="validate"
        phx-submit="save"
      >
        <:actions>
          <.button phx-disable-with="Saving...">Save Receipt</.button>
        </:actions>
      </.simple_form>
    </div>
    """
  end

  @impl true
  def update(%{receipt: receipt} = assigns, socket) do
    changeset = ReceiveFunds.change_receipt(receipt)

    {:ok,
     socket
     |> assign(assigns)
     |> assign_form(changeset)}
  end

  @impl true
  def handle_event("validate", %{"receipt" => receipt_params}, socket) do
    changeset =
      socket.assigns.receipt
      |> ReceiveFunds.change_receipt(receipt_params)
      |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("save", %{"receipt" => receipt_params}, socket) do
    save_receipt(socket, socket.assigns.action, receipt_params)
  end

  defp save_receipt(socket, :edit, receipt_params) do
    case ReceiveFunds.update_receipt(socket.assigns.receipt, receipt_params) do
      {:ok, receipt} ->
        notify_parent({:saved, receipt})

        {:noreply,
         socket
         |> put_flash(:info, "Receipt updated successfully")
         |> push_patch(to: socket.assigns.patch)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  defp save_receipt(socket, :new, receipt_params) do
    case ReceiveFunds.create_receipt(receipt_params) do
      {:ok, receipt} ->
        notify_parent({:saved, receipt})

        {:noreply,
         socket
         |> put_flash(:info, "Receipt created successfully")
         |> push_patch(to: socket.assigns.patch)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    assign(socket, :form, to_form(changeset))
  end

  defp notify_parent(msg), do: send(self(), {__MODULE__, msg})
end
