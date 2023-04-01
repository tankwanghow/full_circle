defmodule FullCircleWeb.ContactLive.Index do
  use FullCircleWeb, :live_view

  alias FullCircle.Accounting
  alias FullCircle.Accounting.Contact

  @per_page 5

  @impl true
  def render(assigns) do
    ~H"""
    <div class="">
      <p class="w-full text-3xl text-center font-medium"><%= @page_title %></p>
      <.search_form search_val={@search.terms} />
      <div class="text-center mb-2">
        <.link phx-click={:new_contact} class={"#{button_css()} text-xl"} id="new_contact">
          <%= gettext("Add New Contact") %>
        </.link>
      </div>
      <div class="text-center grid grid-cols-12 gap-1 mb-1">
        <div class="col-span-4 rounded bg-amber-200 border border-amber-500 font-bold p-2">
          <%= gettext("Name") %>
        </div>
        <div class="col-span-4 rounded bg-amber-200 border border-amber-500 font-bold p-2">
          <%= gettext("Address & Contact") %>
        </div>
        <div class="col-span-4 rounded bg-amber-200 border border-amber-500 font-bold p-2">
          <%= gettext("Descriptions") %>
        </div>
      </div>
      <div id="contacts_list" phx-update={@update}>
        <%= for cont <- @contacts do %>
          <.live_component
            module={FullCircleWeb.ContactLive.ContactIndexComponent}
            id={"contacts-#{cont.id}"}
            contact={cont}
            ex_class=""
          />
        <% end %>
      </div>
      <.infinite_scroll_footer page={@page} count={@contacts_count} per_page={@per_page} />
    </div>

    <.modal
      :if={@live_action in [:new, :edit]}
      id="any-modal"
      show
      on_cancel={JS.push("modal_cancel")}
    >
      <.live_component
        module={@module}
        id={@id}
        title={@title}
        live_action={@live_action}
        form={@form}
        contact={@contact}
        current_company={@current_company}
        current_user={@current_user}
      />
    </.modal>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    contacts = filter_contacts(socket, "", 1)

    socket =
      socket
      |> assign(page_title: gettext("Contacts Listing"))
      |> assign(page: 1, per_page: @per_page)
      |> assign(search: %{terms: ""})
      |> assign(update: "append")
      |> assign(contacts_count: Enum.count(contacts))
      |> assign(contacts: contacts)

    {:ok, socket, temporary_assigns: [contacts: []]}
  end

  @impl true
  def handle_event("modal_cancel", _, socket) do
    {:noreply, socket |> assign(live_action: nil)}
  end

  @impl true
  def handle_event("new_contact", _, socket) do
    {:noreply,
     socket
     |> assign(live_action: :new)
     |> assign(id: "new")
     |> assign(module: FullCircleWeb.ContactLive.FormComponent)
     |> assign(title: gettext("New Contact"))
     |> assign(current_company: socket.assigns.current_company)
     |> assign(current_user: socket.assigns.current_user)
     |> assign(contact: nil)
     |> assign(
       :form,
       to_form(Accounting.contact_changeset(%Contact{}, %{}, socket.assigns.current_company))
     )}
  end

  @impl true
  def handle_event("edit_contact", %{"contact-id" => id}, socket) do
    contact = Accounting.get_contact!(id)

    {:noreply,
     socket
     |> assign(live_action: :edit)
     |> assign(id: id)
     |> assign(module: FullCircleWeb.ContactLive.FormComponent)
     |> assign(title: gettext("Edit Contact"))
     |> assign(current_company: socket.assigns.current_company)
     |> assign(current_user: socket.assigns.current_user)
     |> assign(contact: contact)
     |> assign(
       :form,
       to_form(Accounting.contact_changeset(contact, %{}, socket.assigns.current_company))
     )}
  end

  @impl true
  def handle_event("load-more", _, socket) do
    contacts = filter_contacts(socket, socket.assigns.search.terms, socket.assigns.page + 1)

    {:noreply,
     socket
     |> update(:page, &(&1 + 1))
     |> assign(update: "append")
     |> assign(contacts: contacts)
     |> assign(contacts_count: Enum.count(contacts))}
  end

  @impl true
  def handle_event("search", %{"search" => %{"terms" => terms}}, socket) do
    contacts = filter_contacts(socket, terms, 1)

    {:noreply,
     socket
     |> assign(page: 1, per_page: @per_page)
     |> assign(search: %{terms: terms})
     |> assign(update: "replace")
     |> assign(contacts_count: Enum.count(contacts))
     |> assign(contacts: contacts)}
  end

  @impl true
  def handle_info({:created, cont}, socket) do
    send_update_after(
      self(),
      FullCircleWeb.ContactLive.ContactIndexComponent,
      [id: "contacts-#{cont.id}", contact: cont, ex_class: "shake"],
      400
    )

    {:noreply,
     socket
     |> assign(update: "prepend")
     |> assign(live_action: nil)
     |> assign(contacts: [cont | socket.assigns.contacts])}
  end

  def handle_info({:updated, cont}, socket) do
    send_update_after(
      self(),
      FullCircleWeb.ContactLive.ContactIndexComponent,
      [id: "contacts-#{cont.id}", contact: cont, ex_class: "shake"],
      400
    )

    {:noreply, socket |> assign(live_action: nil)}
  end

  def handle_info({:deleted, cont}, socket) do
    send_update_after(
      self(),
      FullCircleWeb.ContactLive.ContactIndexComponent,
      [id: "contacts-#{cont.id}", ex_class: "hidden"],
      400
    )

    {:noreply,
     socket
     |> put_flash(:info, "#{cont.name} #{gettext("Contact Deleted")}")
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

  defp filter_contacts(socket, terms, page) do
    Accounting.filter_contacts(
      terms,
      socket.assigns.current_company,
      socket.assigns.current_user,
      page: page,
      per_page: @per_page
    )
  end
end
