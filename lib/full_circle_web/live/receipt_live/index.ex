defmodule FullCircleWeb.ReceiptLive.Index do
  use FullCircleWeb, :live_view

  import FullCircleWeb.ListComponents

  alias FullCircle.ReceiveFund
  alias FullCircleWeb.ReceiptLive.IndexComponent
  alias FullCircleWeb.NoteLive.NotesIndex

  @per_page 25
  @selected_max 15

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto w-11/12 max-w-[96rem]">
      <.form for={%{}} id="search-form" phx-submit="search" autocomplete="off">
        <.list_bar title={@page_title}>
          <div class="grow min-w-56">
            <.filter_label>{gettext("Search Terms")}</.filter_label>
            <.input
              id="search_terms"
              name="search[terms]"
              type="search"
              value={@search.terms}
              placeholder="receipt, contact or account..."
            />
          </div>
          <div class="w-36">
            <.filter_label>{gettext("Receipt Date From")}</.filter_label>
            <.input
              name="search[receipt_date]"
              type="date"
              value={@search.receipt_date}
              id="search_receipt_date"
            />
          </div>
          <.button class="h-9 w-10">🔍</.button>
          <:actions>
            <.link
              :if={@can_print}
              navigate={
                ~p"/companies/#{@current_company.id}/Receipt/print_multi?pre_print=false&ids=#{@ids}"
              }
              target="_blank"
              class="blue button"
            >
              {gettext("Print")}{"(#{Enum.count(@selected)})"}
            </.link>
            <.link
              :if={@can_print}
              navigate={
                ~p"/companies/#{@current_company.id}/Receipt/print_multi?pre_print=true&ids=#{@ids}"
              }
              target="_blank"
              class="blue button"
            >
              {gettext("Pre Print")}{"(#{Enum.count(@selected)})"}
            </.link>
            <.link
              navigate={~p"/companies/#{@current_company.id}/Receipt/new"}
              class="blue button"
              id="new_object"
            >
              + {gettext("New Receipt")}
            </.link>
          </:actions>
        </.list_bar>
      </.form>

      <.list_table>
        <:head>
          <div class="w-6 shrink-0"></div>
          <div class="w-24 shrink-0">{gettext("Date")}</div>
          <div class="w-40 shrink-0">{gettext("No.")}</div>
          <div class="flex-1 min-w-0">{gettext("Contact")}</div>
          <div class="w-[24%] shrink-0">{gettext("Particulars")}</div>
          <div class="w-28 shrink-0 text-right">{gettext("Amount")}</div>
          <div class="w-28 shrink-0 text-right">{gettext("Balance")}</div>
          <div class="w-36 shrink-0">{gettext("e-Invoice")}</div>
          <div class="w-6 shrink-0"></div>
        </:head>
        <div
          id="objects_list"
          phx-update="stream"
          phx-page-loading
        >
          <%= for {obj_id, obj} <- @streams.objects do %>
            <.live_component
              module={IndexComponent}
              note_count={Map.get(@note_counts, obj.id, 0)}
              task_count={Map.get(@task_counts, obj.id, 0)}
              id={obj_id}
              obj={obj}
              company={@current_company}
              user={@current_user}
              einv_portal={@einv_portal}
              ex_class=""
            />
          <% end %>
        </div>
      </.list_table>
      <.infinite_scroll_footer ended={@end_of_timeline?} />
      <NotesIndex.modal
        notes_for={@notes_for}
        notes_type={@notes_type}
        current_company={@current_company}
        current_user={@current_user}
      />
    </div>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(page_title: gettext("Receipt Listing"))
      |> NotesIndex.init("Receipt", IndexComponent)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    params = params["search"]
    terms = params["terms"] || ""
    receipt_date = params["receipt_date"] || ""

    {:noreply,
     socket
     |> assign(search: %{terms: terms, receipt_date: receipt_date})
     |> assign(selected: [])
     |> assign(ids: "")
     |> assign(can_print: false)
     |> filter_objects(terms, true, receipt_date, 1)}
  end

  @impl true
  def handle_event("check_click", %{"object-id" => id, "value" => "on"}, socket) do
    obj =
      ReceiveFund.get_receipt_by_id_index_component_field!(
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
      |> FullCircleWeb.Helpers.can_print?(:selected, @selected_max)

    {:noreply, socket |> assign(ids: Enum.join(socket.assigns.selected, ","))}
  end

  @impl true
  def handle_event("check_click", %{"object-id" => id}, socket) do
    obj =
      ReceiveFund.get_receipt_by_id_index_component_field!(
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
      |> FullCircleWeb.Helpers.can_print?(:selected, @selected_max)

    {:noreply, socket |> assign(ids: Enum.join(socket.assigns.selected, ","))}
  end

  @impl true
  def handle_event("next-page", _, socket) do
    {:noreply,
     socket
     |> filter_objects(
       socket.assigns.search.terms,
       false,
       socket.assigns.search.receipt_date,
       socket.assigns.page + 1
     )}
  end

  @impl true
  def handle_event(
        "search",
        %{
          "search" => %{
            "terms" => terms,
            "receipt_date" => id
          }
        },
        socket
      ) do
    qry = %{
      "search[terms]" => terms,
      "search[receipt_date]" => id
    }

    url = "/companies/#{socket.assigns.current_company.id}/Receipt?#{URI.encode_query(qry)}"

    {:noreply, socket |> push_navigate(to: url)}
  end

  defp filter_objects(socket, terms, reset, receipt_date, page) do
    objects =
      ReceiveFund.receipt_index_query(
        terms,
        receipt_date,
        socket.assigns.current_company,
        socket.assigns.current_user,
        page: page,
        per_page: @per_page
      )

    obj_count = Enum.count(objects)

    socket
    |> assign(page: page, per_page: @per_page)
    |> NotesIndex.count(objects, reset)
    |> stream(:objects, objects, reset: reset)
    |> assign(end_of_timeline?: obj_count < @per_page)
  end
end
