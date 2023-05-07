defmodule FullCircleWeb.GoodLive.Index do
  use FullCircleWeb, :live_view

  alias FullCircle.Product.Good
  alias FullCircle.Product
  alias FullCircle.StdInterface
  alias FullCircleWeb.GoodLive.FormComponent
  alias FullCircleWeb.GoodLive.IndexComponent

  @per_page 10

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-2xl mx-auto">
      <p class="w-full text-3xl text-center font-medium"><%= @page_title %></p>
      <.search_form
        search_val={@search.terms}
        placeholder={gettext("Name, Unit, Account Name, TaxCode and Descriptions...")}
      />
      <div class="text-center mb-2">
        <.link phx-click={:new_object} class={"#{button_css()} text-xl"} id="new_object">
          <%= gettext("New Good") %>
        </.link>
      </div>
      <div class="text-center mb-1">
        <div class="rounded bg-amber-200 border border-amber-500 font-bold p-2">
          <%= gettext("Good Information") %>
        </div>
      </div>
      <div id="objects_list" phx-update={@update}>
        <%= for obj <- @objects do %>
          <.live_component
            company={@current_company}
            module={IndexComponent}
            id={"objects-#{obj.id}"}
            obj={obj}
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
      |> assign(page_title: gettext("Good Listing"))
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
     |> assign(title: gettext("New Good"))
     |> assign(current_company: socket.assigns.current_company)
     |> assign(current_user: socket.assigns.current_user)
     |> assign(
       :form,
       to_form(
         StdInterface.changeset(Good, %Good{packagings: []}, %{}, socket.assigns.current_company)
       )
     )}
  end

  @impl true
  def handle_event("edit_object", %{"object-id" => id}, socket) do
    object = Product.get_good!(id, socket.assigns.current_user, socket.assigns.current_company)

    {:noreply,
     socket
     |> assign(live_action: :edit)
     |> assign(id: id)
     |> assign(title: gettext("Edit Good"))
     |> assign(current_company: socket.assigns.current_company)
     |> assign(current_user: socket.assigns.current_user)
     |> assign(
       :form,
       to_form(StdInterface.changeset(Good, object, %{}, socket.assigns.current_company))
     )}
  end

  @impl true
  def handle_event("copy_object", %{"object-id" => id}, socket) do
    object = Product.get_good!(id, socket.assigns.current_user, socket.assigns.current_company)

    {:noreply,
     socket
     |> assign(live_action: :new)
     |> assign(id: "new")
     |> assign(title: gettext("Copying Good"))
     |> assign(current_company: socket.assigns.current_company)
     |> assign(current_user: socket.assigns.current_user)
     |> assign(
       :form,
       to_form(
         StdInterface.changeset(Good, %Good{}, dup_good(object), socket.assigns.current_company)
       )
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
    obj =
      if !Ecto.assoc_loaded?(obj.packagings),
        do: FullCircle.Repo.preload(obj, :packagings),
        else: obj

    css_trans(IndexComponent, obj, :obj, "objects-#{obj.id}", "shake")

    {:noreply,
     socket
     |> assign(update: "prepend")
     |> assign(live_action: nil)
     |> assign(objects: [obj | socket.assigns.objects])}
  end

  def handle_info({:updated, obj}, socket) do
    obj =
      if !Ecto.assoc_loaded?(obj.packagings),
        do: FullCircle.Repo.preload(obj, :packagings),
        else: obj

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
    Product.good_index_query(terms, socket.assigns.current_user, socket.assigns.current_company,
      page: page,
      per_page: @per_page
    )
  end

  defp dup_good(object) do
    %{
      name: object.name <> " - COPY",
      purchase_account_name: object.purchase_account_name,
      sales_account_name: object.sales_account_name,
      purchase_tax_code_name: object.purchase_tax_code_name,
      sales_tax_code_name: object.sales_tax_code_name,
      purchase_account_id: object.purchase_account_id,
      sales_account_id: object.sales_account_id,
      purchase_tax_code_id: object.purchase_tax_code_id,
      sales_tax_code_id: object.sales_tax_code_id,
      unit: object.unit,
      descriptions: object.descriptions,
      packagings: dup_packages(object.packagings)
    }
  end

  defp dup_packages(objects) do
    objects
    |> Enum.map(fn x ->
      %{
        cost_per_package: x.cost_per_package,
        name: x.name,
        unit_multiplier: x.unit_multiplier
      }
    end)
  end
end
