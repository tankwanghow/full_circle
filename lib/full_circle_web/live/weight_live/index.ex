defmodule FullCircleWeb.WeighingLive.Index do
  alias FullCircle.WeightBridge.Weighing
  use FullCircleWeb, :live_view

  alias FullCircle.StdInterface
  alias FullCircleWeb.WeighingLive.IndexComponent

  @per_page 50

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
                placeholder="note no, vehicle or good name..."
              />
            </div>
            <div class="w-[9.5rem] grow-0 shrink-0">
              <label>Note Date From</label>
              <.input
                name="search[date_form]"
                type="date"
                value={@search.date_form}
                id="search_date_form"
              />
            </div>
            <.button class="mt-5 h-10 w-10 grow-0 shrink-0">🔍</.button>
          </div>
        </.form>
      </div>
      <div class="text-center mb-2">
        <.link
          navigate={~p"/companies/#{@current_company.id}/Weighing/new"}
          class="blue button"
          id="new_advance"
        >
          <%= gettext("New Weighing") %>
        </.link>
      </div>
      <div class="font-medium flex flex-row text-center tracking-tighter bg-amber-200">
        <div class="w-[10%] border-b border-t border-amber-400 py-1">
          <%= gettext("Date") %>
        </div>
        <div class="w-[10%] border-b border-t border-amber-400 py-1">
          <%= gettext("Note No") %>
        </div>
        <div class="w-[10%] border-b border-t border-amber-400 py-1">
          <%= gettext("Vechile") %>
        </div>
        <div class="w-[15%] border-b border-t border-amber-400 py-1">
          <%= gettext("Good") %>
        </div>
        <div class="w-[10%] border-b border-t border-amber-400 py-1 text-right pr-2">
          <%= gettext("Gross") %>
        </div>
        <div class="w-[10%] border-b border-t border-amber-400 py-1 text-right pr-2">
          <%= gettext("Tare") %>
        </div>
        <div class="w-[10%] border-b border-t border-amber-400 py-1 text-right pr-2">
          <%= gettext("Nett") %>
        </div>
        <div class="w-[5%] border-b border-t border-amber-400 py-1 pr-2">
          <%= gettext("Unit") %>
        </div>
        <div class="w-[20%] border-b border-t border-amber-400 py-1">
          <%= gettext("Note") %>
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
      |> assign(page_title: gettext("Weighing Listing"))

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    params = params["search"]
    terms = params["terms"] || ""
    df = params["date_form"] || ""

    {:noreply,
     socket
     |> assign(search: %{terms: terms, date_form: df})
     |> filter_objects(terms, df, true, 1)}
  end

  @impl true
  def handle_event("next-page", _, socket) do
    {:noreply,
     socket
     |> filter_objects(
       socket.assigns.search.terms,
       socket.assigns.search.date_form,
       false,
       socket.assigns.page + 1
     )}
  end

  @impl true
  def handle_event(
        "search",
        %{
          "search" => %{
            "terms" => terms,
            "date_form" => df
          }
        },
        socket
      ) do
    qry = %{
      "search[terms]" => terms,
      "search[date_form]" => df
    }

    url = "/companies/#{socket.assigns.current_company.id}/Weighing?#{URI.encode_query(qry)}"

    {:noreply, socket |> push_navigate(to: url)}
  end

  import Ecto.Query, warn: false

  defp filter_objects(socket, terms, df, reset, page) do
    qry =
      from(obj in Weighing,
        join:
          com in subquery(
            FullCircle.Sys.user_company(
              socket.assigns.current_company,
              socket.assigns.current_user
            )
          ),
        on: com.id == obj.company_id,
        order_by: [desc: obj.note_date]
      )

    qry =
      if df != "" do
        from obj in qry, where: obj.note_date >= ^df
      else
        qry
      end

    do_query(socket, qry, terms, reset, page)
  end

  defp do_query(socket, qry, terms, reset, page) do
    objects =
      StdInterface.filter(
        qry,
        [:note_no, :vehicle_no, :good_name, :note],
        terms,
        page: page,
        per_page: @per_page
      )

    socket
    |> assign(page: page, per_page: @per_page)
    |> stream(:objects, objects, reset: reset)
    |> assign(end_of_timeline?: Enum.count(objects) < @per_page)
  end
end
