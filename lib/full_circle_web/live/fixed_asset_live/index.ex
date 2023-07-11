defmodule FullCircleWeb.FixedAssetLive.Index do
  use FullCircleWeb, :live_view

  alias FullCircle.Accounting.FixedAsset
  alias FullCircle.Accounting
  alias FullCircle.StdInterface
  alias FullCircleWeb.FixedAssetLive.{FormComponent, IndexComponent}

  @per_page 20

  @impl true
  def render(assigns) do
    ~H"""
    <div class="w-6/12 mx-auto">
      <p class="w-full text-3xl text-center font-medium"><%= @page_title %></p>
      <.search_form
        search_val={@search.terms}
        placeholder={gettext("Name, Asset Account, Depreciation Account or Descriptions...")}
      />
      <div class="text-center mb-2">
        <.link phx-click={:new_object} class="link_button" id="new_object">
          <%= gettext("New Fixed Asset") %>
        </.link>
        <.link
          navigate={~p"/companies/#{@current_company.id}/fixed_assets/calalldepre"}
          class="link_button"
          id="calculate_depre"
        >
          <%= gettext("Calculate Depreciations") %>
        </.link>
      </div>
      <div class="text-center mb-1">
        <div class="rounded bg-amber-200 border border-amber-500 font-bold p-2">
          <%= gettext("Fixed Asset Information") %>
        </div>
      </div>
      <div
        :if={Enum.count(@streams.objects) > 0 or @page > 1}
        id="objects_list"
        phx-update={@update}
        phx-viewport-bottom={!@end_of_timeline? && "next-page"}
        phx-page-loading
      >
        <%= for {obj_id, obj} <- @streams.objects do %>
          <.live_component
            module={IndexComponent}
            id={"#{obj_id}"}
            obj={obj}
            company={@current_company}
            ex_class=""
            terms={@search.terms}
          />
        <% end %>
      </div>
      <.infinite_scroll_footer ended={@end_of_timeline?} />
    </div>

    <.modal
      :if={@live_action in [:new, :edit]}
      id="object-crud-modal"
      show
      max_w="max-w-4xl"
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
  def mount(params, _session, socket) do
    socket =
      socket
      |> assign(page_title: gettext("Fixed Asset Listing"))
      |> assign(search: %{terms: params["terms"] || ""})
      |> filter_objects(params["terms"] || "", "stream", 1)

    {:ok, socket}
  end

  @impl true
  def handle_event("modal_cancel", _, socket) do
    {:noreply, socket |> assign(live_action: nil)}
  end

  @impl true
  def handle_event("show_depreciation", %{"object-id" => id}, socket) do
    object =
      Accounting.get_fixed_asset!(id, socket.assigns.current_company, socket.assigns.current_user)

    {:noreply,
     socket
     |> assign(live_action: :show)
     |> assign(id: "depreciation")
     |> assign(title: gettext("Depreciations for"))
     |> assign(fixed_asset: object)}
  end

  @impl true
  def handle_event("new_object", _, socket) do
    {:noreply,
     socket
     |> assign(live_action: :new)
     |> assign(id: "new")
     |> assign(title: gettext("New Fixed Asset"))
     |> assign(
       :form,
       to_form(
         StdInterface.changeset(FixedAsset, %FixedAsset{}, %{}, socket.assigns.current_company)
       )
     )}
  end

  @impl true
  def handle_event("edit_object", %{"object-id" => id}, socket) do
    object =
      Accounting.get_fixed_asset!(id, socket.assigns.current_company, socket.assigns.current_user)

    {:noreply,
     socket
     |> assign(live_action: :edit)
     |> assign(id: id)
     |> assign(title: gettext("Edit Fixed Asset"))
     |> assign(
       :form,
       to_form(StdInterface.changeset(FixedAsset, object, %{}, socket.assigns.current_company))
     )}
  end

  @impl true
  def handle_event("next-page", _, socket) do
    {:noreply,
     socket
     |> filter_objects(socket.assigns.search.terms, "stream", socket.assigns.page + 1)}
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
    query =
      Accounting.fixed_asset_query(socket.assigns.current_company, socket.assigns.current_user)

    objects =
      StdInterface.filter(
        query,
        [:name, :asset_ac_name, :depre_ac_name, :descriptions],
        terms,
        page: page,
        per_page: @per_page
      )

    socket
    |> assign(page: page, per_page: @per_page)
    |> assign(search: %{terms: terms})
    |> assign(update: update)
    |> stream(:objects, objects)
    |> assign(end_of_timeline?: Enum.count(objects) < @per_page)
  end
end
