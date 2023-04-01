defmodule FullCircleWeb.ContactLive.FormComponent do
  use FullCircleWeb, :live_component
  alias FullCircle.StdInterface
  alias FullCircle.Accounting.Contact

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
  def handle_event("cancel_delete", _, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("validate", %{"contact" => params}, socket) do
    contact = if(socket.assigns[:contact], do: socket.assigns.contact, else: %Contact{})

    changeset =
      StdInterface.changeset(Contact, contact, params, socket.assigns.current_company)
      |> Map.put(:action, :insert)

    socket = assign(socket, form: to_form(changeset))

    {:noreply, socket}
  end

  @impl true
  def handle_event("save", %{"contact" => params}, socket) do
    save_contact(socket, socket.assigns.live_action, params)
  end

  @impl true
  def handle_event("delete", _params, socket) do
    case StdInterface.delete(
           Contact,
           "contact",
           socket.assigns.contact,
           socket.assigns.current_user,
           socket.assigns.current_company
         ) do
      {:ok, cont} ->
        send(self(), {:deleted, cont})
        {:noreply, socket}

      {:error, failed_operation, changeset, _} ->
        send(self(), {:error, failed_operation, changeset})
        {:noreply, socket}

      :not_authorise ->
        send(self(), :not_authorise)
        {:noreply, socket}
    end
  end

  defp save_contact(socket, :new, params) do
    case StdInterface.create(
           Contact,
           "contact",
           params,
           socket.assigns.current_user,
           socket.assigns.current_company
         ) do
      {:ok, cont} ->
        send(self(), {:created, cont})
        {:noreply, socket}

      {:error, failed_operation, changeset, _} ->
        send(self(), {:error, failed_operation, changeset})
        {:noreply, socket}

      :not_authorise ->
        send(self(), :not_authorise)
        {:noreply, socket}
    end
  end

  defp save_contact(socket, :edit, params) do
    case StdInterface.update(
           Contact,
           "contact",
           socket.assigns.contact,
           params,
           socket.assigns.current_user,
           socket.assigns.current_company
         ) do
      {:ok, cont} ->
        send(self(), {:updated, cont})
        {:noreply, socket}

      {:error, failed_operation, changeset, _} ->
        send(self(), {:error, failed_operation, changeset})
        {:noreply, socket}

      :not_authorise ->
        send(self(), :not_authorise)
        {:noreply, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <p class="w-full text-3xl text-center font-medium"><%= @title %></p>
      <.form
        for={@form}
        id="contact-form"
        phx-target={@myself}
        autocomplete="off"
        phx-change="validate"
        phx-submit="save"
        class="mx-auto"
      >
        <div class="grid grid-cols-12 gap-2">
          <div class="col-span-12">
            <.input field={@form[:name]} label={gettext("Name")} />
          </div>
          <div class="col-span-12">
            <.input field={@form[:address1]} label={gettext("Address Line 1")} />
          </div>
          <div class="col-span-12">
            <.input field={@form[:address2]} label={gettext("Address Line 2")} />
          </div>
          <div class="col-span-6">
            <.input field={@form[:city]} label={gettext("City")} />
          </div>
          <div class="col-span-6">
            <.input field={@form[:zipcode]} label={gettext("Postal Code")} />
          </div>
          <div class="col-span-4  ">
            <.input field={@form[:state]} label={gettext("State")} />
          </div>
          <div class="col-span-4">
            <.input field={@form[:country]} label={gettext("Country")} list="countries" />
          </div>
          <div class="col-span-4">
            <.input field={@form[:reg_no]} label={gettext("Reg No")} />
          </div>
          <div class="col-span-12">
            <.input field={@form[:contact_info]} label={gettext("Contact")} type="textarea" />
          </div>
          <div class="col-span-12">
            <.input field={@form[:descriptions]} label={gettext("Descriptions")} type="textarea" />
          </div>
        </div>
        <%= datalist(FullCircle.Sys.countries(), "countries") %>

        <div class="flex justify-center gap-x-1 mt-1">
          <.button disabled={!@form.source.valid?}><%= gettext("Save") %></.button>
          <%= if @live_action == :edit and FullCircle.Authorization.can?(@current_user, :delete_contact, @current_company) do %>
            <.delete_confirm_modal
              id="delete-contact"
              msg1={gettext("All Contact Transactions, will be LOST!!!")}
              msg2={gettext("Cannot Be Recover!!!")}
              confirm={JS.push("delete", target: "#contact-form")}
              cancel={JS.push("cancel_delete", target: "#contact-form")}
            />
          <% end %>
          <.link phx-click={JS.push("modal_cancel")} class={button_css()}>
            <%= gettext("Back") %>
          </.link>
        </div>
      </.form>
    </div>
    """
  end
end
