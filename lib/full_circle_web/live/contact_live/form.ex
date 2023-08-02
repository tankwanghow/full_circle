defmodule FullCircleWeb.ContactLive.Form do
  use FullCircleWeb, :live_view
  alias FullCircle.StdInterface
  alias FullCircle.Accounting.Contact

  @impl true
  def mount(params, _session, socket) do
    id = params["contact_id"]

    socket =
      case socket.assigns.live_action do
        :new -> mount_new(socket)
        :edit -> mount_edit(socket, id)
      end

    {:ok, socket}
  end

  defp mount_new(socket) do
    socket
    |> assign(live_action: :new)
    |> assign(id: "new")
    |> assign(title: gettext("New Contact"))
    |> assign(
      :form,
      to_form(StdInterface.changeset(Contact, %Contact{}, %{}, socket.assigns.current_company))
    )
  end

  defp mount_edit(socket, id) do
    account = StdInterface.get!(Contact, id)

    socket
    |> assign(live_action: :edit)
    |> assign(id: id)
    |> assign(title: gettext("Edit Contact"))
    |> assign(
      :form,
      to_form(StdInterface.changeset(Contact, account, %{}, socket.assigns.current_company))
    )
  end

  @impl true
  def handle_event("validate", %{"contact" => params}, socket) do
    changeset =
      StdInterface.changeset(
        Contact,
        socket.assigns.form.data,
        params,
        socket.assigns.current_company
      )
      |> Map.put(:action, :insert)

    socket = assign(socket, form: to_form(changeset))

    {:noreply, socket}
  end

  @impl true
  def handle_event("save", %{"contact" => params}, socket) do
    save(socket, socket.assigns.live_action, params)
  end

  @impl true
  def handle_event("delete", _params, socket) do
    case StdInterface.delete(
           Contact,
           "contact",
           socket.assigns.form.data,
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, _ac} ->
        {:noreply,
         socket
         |> push_navigate(to: "/companies/#{socket.assigns.current_company.id}/contacts")
         |> put_flash(:info, "#{gettext("Contact deleted successfully.")}")}

      {:error, failed_operation, changeset, _} ->
        {:noreply,
         socket
         |> assign(form: to_form(changeset))
         |> put_flash(
           :error,
           "#{gettext("Failed")} #{failed_operation}. #{list_errors_to_string(changeset.errors)}"
         )}

      :not_authorise ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("You are not authorised to perform this action"))}
    end
  end

  defp save(socket, :new, params) do
    case StdInterface.create(
           Contact,
           "contact",
           params,
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, ac} ->
        {:noreply,
         socket
         |> push_navigate(
           to: ~p"/companies/#{socket.assigns.current_company.id}/contacts/#{ac.id}/edit"
         )
         |> put_flash(:info, "#{gettext("Contact created successfully.")}")}

      {:error, failed_operation, changeset, _} ->
        {:noreply,
         socket
         |> assign(form: to_form(changeset))
         |> put_flash(
           :error,
           "#{gettext("Failed")} #{failed_operation}. #{list_errors_to_string(changeset.errors)}"
         )}

      :not_authorise ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("You are not authorised to perform this action"))}
    end
  end

  defp save(socket, :edit, params) do
    case StdInterface.update(
           Contact,
           "contact",
           socket.assigns.form.data,
           params,
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, ac} ->
        {:noreply,
         socket
         |> push_navigate(
           to: ~p"/companies/#{socket.assigns.current_company.id}/contacts/#{ac.id}/edit"
         )
         |> put_flash(:info, "#{gettext("Contact updated successfully.")}")}

      {:error, failed_operation, changeset, _} ->
        {:noreply,
         socket
         |> assign(form: to_form(changeset))
         |> put_flash(
           :error,
           "#{gettext("Failed")} #{failed_operation}. #{list_errors_to_string(changeset.errors)}"
         )}

      :not_authorise ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("You are not authorised to perform this action"))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="w-6/12 mx-auto border rounded-lg border-yellow-500 bg-yellow-100 p-4">
      <p class="w-full text-3xl text-center font-medium"><%= @title %></p>
      <.form
        for={@form}
        id="object-form"
        autocomplete="off"
        phx-change="validate"
        phx-submit="save"
        class="mx-auto"
      >
        <div class="grid grid-cols-12 gap-1">
          <div class="col-span-7">
            <.input field={@form[:name]} label={gettext("Name")} />
          </div>
          <div class="col-span-5">
            <.input field={@form[:reg_no]} label={gettext("Reg No")} />
          </div>
          <div class="col-span-6">
            <.input field={@form[:address1]} label={gettext("Address Line 1")} />
          </div>
          <div class="col-span-6">
            <.input field={@form[:address2]} label={gettext("Address Line 2")} />
          </div>
          <div class="col-span-4">
            <.input field={@form[:city]} label={gettext("City")} />
          </div>
          <div class="col-span-2">
            <.input field={@form[:zipcode]} label={gettext("Postal Code")} />
          </div>
          <div class="col-span-3  ">
            <.input field={@form[:state]} label={gettext("State")} />
          </div>
          <div class="col-span-3">
            <.input field={@form[:country]} label={gettext("Country")} list="countries" />
          </div>
          <div class="col-span-6">
            <.input field={@form[:contact_info]} label={gettext("Contact")} type="textarea" />
          </div>
          <div class="col-span-6">
            <.input field={@form[:descriptions]} label={gettext("Descriptions")} type="textarea" />
          </div>
        </div>
        <%= datalist(FullCircle.Sys.countries(), "countries") %>

        <div class="flex justify-center gap-x-1 mt-1">
          <.button disabled={!@form.source.valid?}><%= gettext("Save") %></.button>
          <.link
            :if={Enum.any?(@form.source.changes) and @live_action != :new}
            navigate=""
            class="orange_button"
          >
            <%= gettext("Cancel") %>
          </.link>
          <a onclick="history.back();" class="blue_button"><%= gettext("Back") %></a>
          <%= if @live_action == :edit and FullCircle.Authorization.can?(@current_user, :delete_contact, @current_company) do %>
            <.delete_confirm_modal
              id="delete-object"
              msg1={gettext("All Contact Transactions, will be LOST!!!")}
              msg2={gettext("Cannot Be Recover!!!")}
              confirm={
                JS.push("delete", target: "#object-form")
                |> JS.hide(to: "#delete-object-modal")
              }
            />
          <% end %>
          <.live_component
            :if={@live_action == :edit}
            module={FullCircleWeb.LogLive.Component}
            id={"log_#{@id}"}
            show_log={false}
            entity="contacts"
            entity_id={@id}
          />
        </div>
      </.form>
    </div>
    """
  end
end
