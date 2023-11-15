defmodule FullCircleWeb.PaymentLive.Index do
  use FullCircleWeb, :live_view

  alias FullCircle.BillPay
  alias FullCircleWeb.PaymentLive.IndexComponent

  @per_page 25

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto w-8/12">
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
                placeholder="payment, contact or account..."
              />
            </div>
            <div class="w-[9.5rem] grow-0 shrink-0">
              <label>Payment Date From</label>
              <.input
                name="search[payment_date]"
                type="date"
                value={@search.payment_date}
                id="search_payment_date"
              />
            </div>
            <.button class="mt-5 h-10 w-10 grow-0 shrink-0">🔍</.button>
          </div>
        </.form>
      </div>
      <div class="text-center mb-2">
        <.link
          navigate={~p"/companies/#{@current_company.id}/Payment/new"}
          class="blue button"
          id="new_object"
        >
          <%= gettext("New Payment") %>
        </.link>
        <.link
          :if={@ids != ""}
          navigate={
            ~p"/companies/#{@current_company.id}/Payment/print_multi?pre_print=false&ids=#{@ids}"
          }
          target="_blank"
          class="blue button"
        >
          <%= gettext("Print") %>
        </.link>
        <.link
          :if={@ids != ""}
          navigate={
            ~p"/companies/#{@current_company.id}/Payment/print_multi?pre_print=true&ids=#{@ids}"
          }
          target="_blank"
          class="blue button"
        >
          <%= gettext("Pre Print") %>
        </.link>
      </div>
      <div class="font-medium flex flex-row text-center tracking-tighter bg-amber-200">
        <div class="w-[2%] border-b border-t border-amber-400 py-1"></div>
        <div class="w-[10%] border-b border-t border-amber-400 py-1">
          <%= gettext("Date") %>
        </div>
        <div class="w-[10%] border-b border-t border-amber-400 py-1">
          <%= gettext("Payment No") %>
        </div>
        <div class="w-[28%] border-b border-t border-amber-400 py-1">
          <%= gettext("Contact") %>
        </div>
        <div class="w-[40%] border-b border-t border-amber-400 py-1">
          <%= gettext("Particulars") %>
        </div>
        <div class="w-[10%] border-b border-t border-amber-400 py-1">
          <%= gettext("Amount") %>
        </div>
      </div>
      <div
        :if={Enum.count(@streams.objects) > 0 or @page > 1}
        id="objects_list"
        phx-update="stream"
        phx-viewport-bottom={!@end_of_timeline? && "next-page"}
        phx-page-loading
      >
        <%= for {obj_id, obj} <- @streams.objects do %>
          <.live_component
            module={IndexComponent}
            id={obj_id}
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

      |> assign(page_title: gettext("Payment Listing"))

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    params = params["search"]
    terms = params["terms"] || ""
    payment_date = params["payment_date"] || ""

    {:noreply,
     socket
     |> assign(search: %{terms: terms, payment_date: payment_date})
     |> assign(selected: [])

     |> assign(ids: "")
     |> filter_objects(terms, true, payment_date, 1)}
  end

  @impl true
  def handle_event("check_click", %{"object-id" => id, "value" => "on"}, socket) do
    obj =
      BillPay.get_payment_by_id_index_component_field!(
        id,
        socket.assigns.current_company,
        socket.assigns.current_user
      )

    Phoenix.LiveView.send_update(
      self(),
      IndexComponent,
      [{:id, "objects-#{id}"}, {:obj, Map.merge(obj, %{checked: true})}]
    )

    socket =
      socket
      |> assign(selected: [id | socket.assigns.selected])

    {:noreply, socket |> assign(ids: Enum.join(socket.assigns.selected, ","))}
  end

  @impl true
  def handle_event("check_click", %{"object-id" => id}, socket) do
    obj =
      BillPay.get_payment_by_id_index_component_field!(
        id,
        socket.assigns.current_company,
        socket.assigns.current_user
      )

    Phoenix.LiveView.send_update(
      self(),
      IndexComponent,
      [{:id, "objects-#{id}"}, {:obj, Map.merge(obj, %{checked: false})}]
    )

    socket =
      socket
      |> assign(selected: Enum.reject(socket.assigns.selected, fn sid -> sid == id end))

    {:noreply, socket |> assign(ids: Enum.join(socket.assigns.selected, ","))}
  end

  @impl true
  def handle_event("next-page", _, socket) do
    {:noreply,
     socket

     |> filter_objects(
       socket.assigns.search.terms,
       false,
       socket.assigns.search.payment_date,
       socket.assigns.page + 1
     )}
  end

  @impl true
  def handle_event(
        "search",
        %{
          "search" => %{
            "terms" => terms,
            "payment_date" => id
          }
        },
        socket
      ) do
    qry = %{
      "search[terms]" => terms,
      "search[payment_date]" => id
    }

    url = "/companies/#{socket.assigns.current_company.id}/Payment?#{URI.encode_query(qry)}"

    {:noreply, socket |> push_patch(to: url)}
  end

  defp filter_objects(socket, terms, reset, payment_date, page) do
    objects =
      BillPay.payment_index_query(
        terms,
        payment_date,
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
end
