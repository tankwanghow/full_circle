defmodule FullCircleWeb.TaxCodeLive.Index do
  use FullCircleWeb, :live_view

  alias FullCircle.Accounting.TaxCode
  alias FullCircle.Accounting
  alias FullCircle.StdInterface
  alias FullCircleWeb.TaxCodeLive.FormComponent
  alias FullCircleWeb.TaxCodeLive.IndexComponent

  @per_page 10

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-2xl mx-auto">
      <p class="w-full text-3xl text-center font-medium"><%= @page_title %></p>
      <.search_form
        search_val={@search.terms}
        placeholder={gettext("Code, Tax Type, Account Name and Descriptions...")}
      />
      <div class="text-center mb-2">
        <.link phx-click={:new_object} class={"#{button_css()} text-xl"} id="new_object">
          <%= gettext("Add New TaxCode") %>
        </.link>
      </div>
      <div class="text-center mb-1">
        <div class="rounded bg-amber-200 border border-amber-500 font-bold p-2">
          <%= gettext("TaxCode Information") %>
        </div>
      </div>
      <div id="objects_list" phx-update={@update}>
        <%= for obj <- @objects do %>
          <.live_component module={IndexComponent} id={"objects-#{obj.id}"} obj={obj} ex_class="" />
        <% end %>
      </div>
      <.infinite_scroll_footer page={@page} count={@objects_count} per_page={@per_page} />
    </div>

    <.modal
      :if={@live_action in [:new, :edit]}
      id="any-modal"
      show
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
    objects = filter_objects(socket, "", 1)

    socket =
      socket
      |> assign(page_title: gettext("TaxCode Listing"))
      |> assign(page: 1, per_page: @per_page)
      |> assign(search: %{terms: ""})
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
     |> assign(title: gettext("New TaxCode"))
     |> assign(current_company: socket.assigns.current_company)
     |> assign(current_user: socket.assigns.current_user)
     |> assign(
       :form,
       to_form(StdInterface.changeset(TaxCode, %TaxCode{}, %{}, socket.assigns.current_company))
     )}
  end

  @impl true
  def handle_event("edit_object", %{"object-id" => id}, socket) do
    object =
      Accounting.get_tax_code!(id, socket.assigns.current_user, socket.assigns.current_company)

    {:noreply,
     socket
     |> assign(live_action: :edit)
     |> assign(id: id)
     |> assign(title: gettext("Edit TaxCode"))
     |> assign(current_company: socket.assigns.current_company)
     |> assign(current_user: socket.assigns.current_user)
     |> assign(
       :form,
       to_form(StdInterface.changeset(TaxCode, object, %{}, socket.assigns.current_company))
     )}
  end

  @impl true
  def handle_event("load-more", _, socket) do
    objects = filter_objects(socket, socket.assigns.search.terms, socket.assigns.page + 1)

    {:noreply,
     socket
     |> update(:page, &(&1 + 1))
     |> assign(update: "append")
     |> assign(objects: objects)
     |> assign(objects_count: Enum.count(objects))}
  end

  @impl true
  def handle_event("search", %{"search" => %{"terms" => terms}}, socket) do
    objects = filter_objects(socket, terms, 1)

    {:noreply,
     socket
     |> assign(page: 1, per_page: @per_page)
     |> assign(search: %{terms: terms})
     |> assign(update: "replace")
     |> assign(objects_count: Enum.count(objects))
     |> assign(objects: objects)}
  end

  @impl true
  def handle_info({:created, obj}, socket) do
    css_trans(IndexComponent, obj, :obj, "objects-#{obj.id}", "shake")

    {:noreply,
     socket
     |> assign(update: "prepend")
     |> assign(live_action: nil)
     |> assign(objects: [obj | socket.assigns.objects])}
  end

  def handle_info({:updated, obj}, socket) do
    css_trans(IndexComponent, obj, :obj, "objects-#{obj.id}", "shake")

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

  defp filter_objects(socket, terms, page) do
    query = Accounting.tax_code_query(socket.assigns.current_user, socket.assigns.current_company)

    StdInterface.filter(query, [:code, :tax_type, :account_name, :descriptions], terms,
      page: page,
      per_page: @per_page
    )
  end
end
