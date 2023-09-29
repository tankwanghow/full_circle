defmodule FullCircleWeb.TimeAttendLive.Index do
  use FullCircleWeb, :live_view

  alias FullCircle.HR
  alias FullCircleWeb.TimeAttendLive.IndexComponent

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
                placeholder="employee, flag or input medium..."
              />
            </div>
            <div class="w-[9.5rem] grow-0 shrink-0">
              <label>Punch Date From</label>
              <.input
                name="search[punch_date]"
                type="date"
                value={@search.punch_date}
                id="search_punch_date"
              />
            </div>
            <.button class="mt-5 h-10 w-10 grow-0 shrink-0">🔍</.button>
          </div>
        </.form>
      </div>
      <div class="text-center mb-2">
        <.link
          navigate={~p"/companies/#{@current_company.id}/TimeAttend/new"}
          class="blue button"
          id="new_timeattend"
        >
          <%= gettext("New Time Attendence") %>
        </.link>
      </div>
      <div class="font-medium flex flex-row text-center tracking-tighter bg-amber-200">
        <div class="w-[30%] border-b border-t border-amber-400 py-1">
          <%= gettext("Employee") %>
        </div>
        <div class="w-[15%] border-b border-t border-amber-400 py-1">
          <%= gettext("Punch Date Time") %>
        </div>
        <div class="w-[10%] border-b border-t border-amber-400 py-1">
          <%= gettext("IN/OUT") %>
        </div>
        <div class="w-[10%] border-b border-t border-amber-400 py-1">
          <%= gettext("Medium") %>
        </div>
        <div class="w-[20%] border-b border-t border-amber-400 py-1">
          <%= gettext("Touch By") %>
        </div>
        <div class="w-[15%] border-b border-t border-amber-400 py-1">
          <%= gettext("Touch At") %>
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
      |> assign(page_title: gettext("TimeAttend Listing"))

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    params = params["search"]
    terms = params["terms"] || ""
    punch_date = params["punch_date"] || ""

    {:noreply,
     socket
     |> assign(
       search: %{terms: terms, punch_date: punch_date}
     )
     |> assign(selected_timeattends: [])
     |> assign(ids: "")
     |> filter_objects(terms, "replace", punch_date, 1)}
  end

  @impl true
  def handle_event("next-page", _, socket) do
    {:noreply,
     socket
     |> filter_objects(
       socket.assigns.search.terms,
       "stream",
       socket.assigns.search.punch_date,
       socket.assigns.page + 1
     )}
  end

  @impl true
  def handle_event(
        "search",
        %{
          "search" => %{
            "terms" => terms,
            "punch_date" => id
          }
        },
        socket
      ) do
    qry = %{
      "search[terms]" => terms,
      "search[punch_date]" => id
    }

    url = "/companies/#{socket.assigns.current_company.id}/TimeAttend?#{URI.encode_query(qry)}"

    {:noreply, socket |> push_patch(to: url)}
  end

  defp filter_objects(socket, terms, update, punch_date, page) do
    objects =
      HR.timeattend_index_query(
        terms,
        punch_date,
        socket.assigns.current_company,
        socket.assigns.current_user,
        page: page,
        per_page: @per_page
      )

    obj_count = Enum.count(objects)

    socket
    |> assign(page: page, per_page: @per_page)
    |> assign(update: update)
    |> stream(:objects, objects, reset: obj_count == 0)
    |> assign(end_of_timeline?: obj_count < @per_page)
  end
end
