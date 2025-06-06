defmodule FullCircleWeb.DebitNoteLive.Index do
  use FullCircleWeb, :live_view

  alias FullCircle.DebCre
  alias FullCircleWeb.DebitNoteLive.IndexComponent

  @per_page 25
  @selected_max 15

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto w-11/12">
      <p class="w-full text-3xl text-center font-medium">{@page_title}</p>
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
                placeholder="debit note, contact or account..."
              />
            </div>
            <div class="w-[9.5rem] grow-0 shrink-0">
              <label>Debit Note Date From</label>
              <.input
                name="search[note_date]"
                type="date"
                value={@search.note_date}
                id="search_note_date"
              />
            </div>
            <.button class="mt-5 h-10 w-10 grow-0 shrink-0">🔍</.button>
          </div>
        </.form>
      </div>
      <div class="text-center mb-2">
        <.link
          navigate={~p"/companies/#{@current_company.id}/DebitNote/new"}
          class="blue button"
          id="new_object"
        >
          {gettext("New Debit Note")}
        </.link>
        <.link
          :if={@can_print}
          navigate={
            ~p"/companies/#{@current_company.id}/CreditNote/print_multi?pre_print=false&ids=#{@ids}"
          }
          target="_blank"
          class="blue button"
        >
          {gettext("Print")}{"(#{Enum.count(@selected)})"}
        </.link>
        <.link
          :if={@can_print}
          navigate={
            ~p"/companies/#{@current_company.id}/CreditNote/print_multi?pre_print=true&ids=#{@ids}"
          }
          target="_blank"
          class="blue button"
        >
          {gettext("Pre Print")}{"(#{Enum.count(@selected)})"}
        </.link>
      </div>
      <div class="font-medium flex flex-row text-center tracking-tighter bg-amber-200">
        <div class="w-[2%] border-b border-t border-amber-400 py-1"></div>
        <div class="w-[15%] border-b border-t border-amber-400 py-1">
          {gettext("Date / Debit No / TIN / RegNo")}
        </div>
        <div class="w-[25%] border-b border-t border-amber-400 py-1">
          {gettext("Contact / Particulars")}
        </div>
        <div class="w-[8%] border-b border-t border-amber-400 py-1">
          {gettext("Amount")}
        </div>
        <div class="w-[0.4%] bg-white"></div>
        <div class="font-medium flex flex-row bg-blue-200 w-[49.6%]">
          <div class="w-[22%] border-b border-t border-blue-400 p-1">
            <div>{gettext("Received/ Issued/ Reject")}</div>
          </div>
          <div class="w-[36%] border-b border-t border-blue-400 p-1">
            <div>{gettext("UUD/ InternalId/ Direction/ Type/ Version")}</div>
          </div>
          <div class="w-[42%] border-b border-t border-blue-400 p-1">
            <div>{gettext("ContactName/ TIN/ Amount")}</div>
          </div>
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
            user={@current_user}
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
      |> assign(page_title: gettext("Debit Note Listing"))

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    params = params["search"]
    terms = params["terms"] || ""
    note_date = params["note_date"] || ""

    {:noreply,
     socket
     |> assign(search: %{terms: terms, note_date: note_date})
     |> assign(selected: [])
     |> assign(ids: "")
     |> assign(can_print: false)
     |> filter_objects(terms, true, note_date, 1)}
  end

  @impl true
  def handle_event("check_click", %{"object-id" => id, "value" => "on"}, socket) do
    obj =
      DebCre.get_debit_note_by_id_index_component_field!(
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
      DebCre.get_debit_note_by_id_index_component_field!(
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
       socket.assigns.search.note_date,
       socket.assigns.page + 1
     )}
  end

  @impl true
  def handle_event(
        "search",
        %{
          "search" => %{
            "terms" => terms,
            "note_date" => id
          }
        },
        socket
      ) do
    qry = %{
      "search[terms]" => terms,
      "search[note_date]" => id
    }

    url = "/companies/#{socket.assigns.current_company.id}/DebitNote?#{URI.encode_query(qry)}"

    {:noreply, socket |> push_navigate(to: url)}
  end

  defp filter_objects(socket, terms, reset, note_date, page) do
    objects =
      DebCre.debit_note_index_query(
        terms,
        note_date,
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
