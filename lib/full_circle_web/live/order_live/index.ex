defmodule FullCircleWeb.OrderLive.Index do
  use FullCircleWeb, :live_view

  alias FullCircle.Product
  alias FullCircleWeb.OrderLive.IndexComponent

  @per_page 25

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto w-10/12">
      <p class="w-full text-3xl text-center font-medium"><%= @page_title %></p>
      <div class="flex justify-center mb-2">
        <.form for={%{}} id="search-form" phx-submit="search" autocomplete="off" class="w-full">
          <div class=" flex flex-row flex-wrap tracking-tighter text-sm">
            <div class="w-[15.5rem] grow shrink">
              <label class="">Search Terms</label>
              <.input
                id="search_terms"
                name="search[terms]"
                type="search"
                value={@search.terms}
                placeholder="Order no, customer, status or particulars..."
              />
            </div>
            <div class="w-[9.5rem] grow-0 shrink-0">
              <label>Order Date From</label>
              <.input
                name="search[order_date]"
                type="date"
                value={@search.order_date}
                id="search_load_date"
              />
            </div>
            <div class="w-[9.5rem] grow-0 shrink-0">
              <label>ETD Date From</label>
              <.input
                name="search[etd_date]"
                type="date"
                value={@search.etd_date}
                id="search_etd_date"
              />
            </div>
            <.button class="mt-5 h-10 w-10 grow-0 shrink-0">🔍</.button>
          </div>
        </.form>
      </div>
      <div class="text-center mb-2">
        <.link
          navigate={~p"/companies/#{@current_company.id}/Order/new"}
          class="blue button"
          id="new_order"
        >
          <%= gettext("New Order") %>
        </.link>
        <.link
          :if={@can_load}
          navigate={~p"/companies/#{@current_company.id}/Load/new?ids=#{selected_ids(@selected)}"}
          class="blue button"
        >
          <%= gettext("Send For Loading") %>
        </.link>
      </div>
      <div class="font-medium flex flex-row text-center tracking-tighter bg-amber-200">
        <div class="w-[2%] border-b border-t border-amber-400 py-1"></div>
        <div class="w-[9%] border-b border-t border-amber-400 py-1">
          <%= gettext("Date") %>
        </div>
        <div class="w-[10%] border-b border-t border-amber-400 py-1">
          <%= gettext("Order No") %>
        </div>
        <div class="w-[20%] border-b border-t border-amber-400 py-1">
          <%= gettext("Contact") %>
        </div>
        <div class="w-[19%] border-b border-t border-amber-400 py-1">
          <%= gettext("Goods") %>
        </div>
        <div class="w-[10%] border-b border-t border-amber-400 py-1">
          <%= gettext("Quantity") %>
        </div>
        <div class="w-[10%] text-green-500  border-b border-t border-amber-400 py-1">
          <%= gettext("Loaded") %>
        </div>
        <div class="w-[10%] text-amber-600 border-b border-t border-amber-400 py-1">
          <%= gettext("Delivered") %>
        </div>
        <div class="w-[10%] border-b border-t border-amber-400 py-1">
          <%= gettext("Status") %>
        </div>
      </div>
      <div
        :if={Enum.count(@streams.objects) > 0 or @page > 1}
        id="objects_list"
        phx-update="stream"
        phx-viewport-bottom={!@end_of_timeline? && "next-page"}
        phx-page-loading
      >
        <%= for {_obj_id, obj} <- @streams.objects do %>
          <.live_component
            module={IndexComponent}
            id={"#{obj.line_id}"}
            obj={obj}
            company={@current_company}
            ex_class=""
          />
        <% end %>
      </div>
      <.infinite_scroll_footer ended={@end_of_timeline?} />
    </div>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(page_title: gettext("Order Listing"))

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    params = params["search"]

    terms = params["terms"] || ""
    order_date = params["order_date"] || ""
    etd_date = params["etd_date"] || ""

    {:noreply,
     socket
     |> assign(search: %{terms: terms, order_date: order_date, etd_date: etd_date})
     |> assign(selected: [])
     |> assign(can_load: false)
     |> filter_objects(terms, true, order_date, etd_date, 1)}
  end

  @impl true
  def handle_event("check_click", %{"object-id" => id, "value" => "on"}, socket) do
    obj =
      Product.get_order_line_by_id_index_component_field!(
        id,
        socket.assigns.current_company,
        socket.assigns.current_user
      )

    Phoenix.LiveView.send_update(
      self(),
      IndexComponent,
      [{:id, "#{id}"}, {:obj, Map.merge(obj, %{checked: true})}]
    )

    socket =
      socket
      |> assign(selected: [obj | socket.assigns.selected])

    {:noreply,
     socket
     |> assign(can_load: can_load?(socket))}
  end

  @impl true
  def handle_event("check_click", %{"object-id" => id}, socket) do
    obj =
      Product.get_order_line_by_id_index_component_field!(
        id,
        socket.assigns.current_company,
        socket.assigns.current_user
      )

    Phoenix.LiveView.send_update(
      self(),
      IndexComponent,
      [{:id, "#{id}"}, {:obj, Map.merge(obj, %{checked: false})}]
    )

    socket =
      socket
      |> assign(selected: Enum.reject(socket.assigns.selected, fn o -> o.line_id == id end))

    {:noreply,
     socket
     |> assign(can_load: can_load?(socket))}
  end

  @impl true
  def handle_event("next-page", _, socket) do
    {:noreply,
     socket
     |> filter_objects(
       socket.assigns.search.terms,
       false,
       socket.assigns.search.order_date,
       socket.assigns.search.etd_date,
       socket.assigns.page + 1
     )}
  end

  @impl true
  def handle_event(
        "search",
        %{
          "search" => %{
            "terms" => terms,
            "order_date" => id,
            "etd_date" => etd
          }
        },
        socket
      ) do
    qry = %{
      "search[terms]" => terms,
      "search[order_date]" => id,
      "search[etd_date]" => etd
    }

    url = "/companies/#{socket.assigns.current_company.id}/Order?#{URI.encode_query(qry)}"

    {:noreply, socket |> push_patch(to: url)}
  end

  defp filter_objects(socket, terms, reset, order_date, etd_date, page) do
    objects =
      Product.order_index_query(
        terms,
        order_date,
        etd_date,
        socket.assigns.current_company,
        socket.assigns.current_user,
        page: page,
        per_page: @per_page
      )

    obj_count = Enum.count(objects)

    socket
    |> assign(page: page, per_page: @per_page)
    |> stream(:objects, objects, reset: reset)
    |> assign(end_of_timeline?: obj_count < @per_page)
  end

  defp selected_ids(selected) do
    selected |> Enum.map(fn x -> x.line_id end) |> Enum.join(",")
  end

  defp can_load?(socket) do
    is_nil(
      socket.assigns.selected
      |> Enum.find(fn x ->
        x.status == "Cancel" or x.status == "Delivered" or x.status == "Hold"
      end)
    )
  end
end
