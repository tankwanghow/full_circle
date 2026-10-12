defmodule FullCircleWeb.ContactLive.BankComponent do
  @moduledoc "Supplier bank details on the contact form. Rendered only for :manage_contact_bank."
  use FullCircleWeb, :live_component

  alias FullCircle.Accounting
  alias FullCircle.Accounting.Contact
  alias FullCircle.BankPayment.Banks

  # The parent passes its original contact struct on every re-render; keep our
  # own copy after mount so a re-render never brings back stale bank details.
  @impl true
  def update(assigns, socket) do
    socket = assign(socket, Map.delete(assigns, :contact))

    if socket.assigns[:form] do
      {:ok, socket}
    else
      {:ok,
       socket
       |> assign(contact: assigns.contact, saved: false)
       |> assign(form: to_form(Contact.bank_changeset(assigns.contact, %{}), as: :contact_bank))}
    end
  end

  @impl true
  def handle_event("validate", %{"contact_bank" => params}, socket) do
    cs = socket.assigns.contact |> Contact.bank_changeset(params) |> Map.put(:action, :validate)
    {:noreply, assign(socket, form: to_form(cs, as: :contact_bank), saved: false)}
  end

  @impl true
  def handle_event("save", %{"contact_bank" => params}, socket) do
    case Accounting.save_contact_bank(
           socket.assigns.contact,
           params,
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, contact} ->
        {:noreply,
         socket
         |> assign(contact: contact, saved: true)
         |> assign(form: to_form(Contact.bank_changeset(contact, %{}), as: :contact_bank))}

      {:error, cs} ->
        {:noreply,
         assign(socket,
           form: to_form(Map.put(cs, :action, :validate), as: :contact_bank),
           saved: false
         )}

      :not_authorise ->
        {:noreply, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id={@id}
      class="mt-2 border rounded-lg border-emerald-500 bg-emerald-50 dark:bg-emerald-900/30 p-2"
    >
      <p class="font-semibold">{gettext("Bank details")}</p>
      <.form
        for={@form}
        id="contact-bank-form"
        phx-target={@myself}
        phx-change="validate"
        phx-submit="save"
        autocomplete="off"
      >
        <div class="grid grid-cols-12 gap-1">
          <div class="col-span-5">
            <.input
              field={@form[:bank_code]}
              type="select"
              label={gettext("Bank")}
              options={Banks.options()}
              prompt={gettext("-- none --")}
            />
          </div>
          <div class="col-span-3">
            <.input field={@form[:bank_account_no]} label={gettext("Account No")} inputmode="numeric" />
          </div>
          <div class="col-span-4">
            <.input
              field={@form[:bank_account_name]}
              label={gettext("Account Holder Name")}
              value={@form[:bank_account_name].value || @contact.name}
            />
          </div>
        </div>
        <div class="flex justify-center items-center gap-x-2 mt-1">
          <button type="submit" class="blue button" id="save-bank">
            {gettext("Save Bank Details")}
          </button>
          <span :if={@saved} class="text-emerald-700 dark:text-emerald-300">{gettext("Saved")}</span>
          <.live_component
            module={FullCircleWeb.LogLive.Component}
            current_company={@current_company}
            id={"log_bank_#{@contact.id}"}
            show_log={false}
            entity="contact_bank"
            entity_id={@contact.id}
          />
        </div>
      </.form>
    </div>
    """
  end
end
