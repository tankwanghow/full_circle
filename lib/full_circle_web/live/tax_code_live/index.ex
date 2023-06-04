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
          <%= gettext("New TaxCode") %>
        </.link>
      </div>
      <div class="text-center mb-1">
        <div class="rounded bg-amber-200 border border-amber-500 font-bold p-2">
          <%= gettext("TaxCode Information") %>
        </div>
      </div>
      <div
        id="objects_list"
        phx-update={@update}
        phx-viewport-top={@page > 1 && "prev-page"}
        phx-viewport-bottom={!@end_of_timeline? && "next-page"}
        phx-page-loading
        class={[
          if(@end_of_timeline?, do: "pb-2", else: "pb-[calc(200vh)]"),
          if(@page == 1, do: "pt-2", else: "pt-[calc(200vh)]")
        ]}
      >
        <%= for {obj_id, obj} <- @streams.objects do %>
          <.live_component module={IndexComponent} id={"#{obj_id}"} obj={obj} ex_class="" />
        <% end %>
      </div>
      <div
        :if={@end_of_timeline?}
        class="mt-2 mb-2 text-center border-2 rounded bg-orange-200 border-orange-400 p-2"
      >
        <%= gettext("No More.") %>
      </div>
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
    socket =
      socket
      |> assign(page_title: gettext("TaxCode Listing"))
      |> filter_objects("", "stream", 1)

    {:ok, socket}
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
  def handle_event("next-page", _, socket) do
    {:noreply,
     socket
     |> filter_objects(socket.assigns.search.terms, "stream", socket.assigns.page + 1)}
  end

  @impl true
  def handle_event("prev-page", %{"_overran" => true}, socket) do
    {:noreply,
     socket
     |> filter_objects(socket.assigns.search.terms, "stream", 1)}
  end

  @impl true
  def handle_event("prev-page", _, socket) do
    if socket.assigns.page > 1 do
      {:noreply,
       socket
       |> filter_objects(socket.assigns.search.terms, "stream", socket.assigns.page - 1)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("search", %{"search" => %{"terms" => terms}}, socket) do
    {:noreply,
     socket
     |> filter_objects(terms, "replace", 1)}
  end

  @impl true
  def handle_info({:created, obj}, socket) do
    css_trans(IndexComponent, obj, :obj, "objects-#{obj.id}", "shake")

    {:noreply,
     socket
     |> assign(live_action: nil)
     |> stream_insert(:objects, obj, at: 0)}
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

  defp filter_objects(socket, terms, update, page) do
    query = Accounting.tax_code_query(socket.assigns.current_user, socket.assigns.current_company)

    objects =
      StdInterface.filter(query, [:code, :tax_type, :account_name, :descriptions], terms,
        page: page,
        per_page: @per_page
      )

    socket
    |> assign(page: page, per_page: @per_page)
    |> assign(search: %{terms: terms})
    |> assign(update: update)
    |> stream(:objects, objects)
    |> assign(end_of_timeline?: Enum.count(objects) == 0)
  end
end
