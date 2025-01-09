defmodule FullCircleWeb.EInvListLive.Index do
  use FullCircleWeb, :live_view
  import Ecto.Query, warn: false

  alias FullCircleWeb.EInvListLive.IndexComponent

  @per_page 20

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(update_action: "stream")
      |> assign(min_date: Date.shift(Timex.today(), day: -30))
      |> assign(max_date: Timex.today())
      |> stream_configure(:objects, dom_id: & &1["uuid"])
      |> assign(page_title: gettext("E-Invoices Listing"))

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    params = params["search"]

    direction = params["direction"] || "Received"
    f_date = params["f_date"] || Date.shift(Timex.today(), day: -30)
    t_date = params["t_date"] || Timex.today()

    socket =
      socket
      |> assign(search: %{direction: direction, f_date: f_date, t_date: t_date})

    {:noreply,
     socket
     |> assign(update_action: "stream")
     |> filter_objects(true, 1)}
  end

  @impl true
  def handle_event("next-page", _, socket) do
    {:noreply,
     socket
     |> filter_objects(false, socket.assigns.page + 1)}
  end

  @impl true
  def handle_event(
        "search",
        %{"search" => %{"direction" => direction, "f_date" => f_date, "t_date" => t_date}},
        socket
      ) do
    qry = %{
      "search[direction]" => direction,
      "search[f_date]" => f_date,
      "search[t_date]" => t_date
    }

    url = "/companies/#{socket.assigns.current_company.id}/e_invoices?#{URI.encode_query(qry)}"

    {:noreply, socket |> push_navigate(to: url)}
  end

  @impl true
  def handle_event(
        "validate",
        %{
          "_target" => ["search", "f_date"],
          "search" => %{"direction" => dir, "f_date" => fdate, "t_date" => tdate}
        },
        socket
      ) do
    {:noreply,
     socket
     |> assign(search: %{direction: dir, f_date: fdate, t_date: tdate})
     |> assign(max_date: Date.shift(Date.from_iso8601!(fdate), day: 30))}
  end

  @impl true
  def handle_event(
        "validate",
        %{
          "_target" => ["search", "t_date"],
          "search" => %{"direction" => dir, "f_date" => fdate, "t_date" => tdate}
        },
        socket
      ) do
    {:noreply,
     socket
     |> assign(search: %{direction: dir, f_date: fdate, t_date: tdate})
     |> assign(min_date: Date.shift(Date.from_iso8601!(tdate), day: -30))}
  end

  @impl true
  def handle_event("validate", _, socket) do
    {:noreply, socket}
  end

  defp filter_objects(socket, reset, page) when page >= 1 do
    objects =
      FullCircle.EInvMetas.get_e_invoices(
        socket.assigns.search.direction,
        socket.assigns.search.f_date,
        socket.assigns.search.t_date,
        @per_page,
        page,
        socket.assigns.current_company.id,
        socket.assigns.current_user.id
      )

    socket
    |> assign(page: page)
    |> stream(:objects, objects, reset: reset)
    |> assign(end_of_timeline?: Enum.count(objects) < @per_page)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto w-10/12">
      <p class="w-full text-3xl text-center font-medium"><%= @page_title %></p>
      <div class="flex justify-center mb-2">
        <.form
          for={%{}}
          id="search-form"
          phx-submit="search"
          autocomplete="off"
          class="w-full"
          phx-change="validate"
        >
          <div class=" flex flex-row flex-wrap tracking-tighter text-sm">
            <div class="w-[7rem] grow-0 shrink-0">
              <label>Balance</label>
              <.input
                name="search[direction]"
                type="select"
                options={~w(Received Sent)}
                value={@search.direction}
                id="search_direction"
              />
            </div>
            <div class="w-[9.5rem] grow-0 shrink-0">
              <label>IssuedDate From</label>
              <.input
                name="search[f_date]"
                type="date"
                value={@search.f_date}
                id="search_f_date"
                min={@min_date}
                max={@search.t_date}
              />
            </div>
            <div class="w-[9.5rem] grow-0 shrink-0">
              <label>IssuedDate End</label>
              <.input
                name="search[t_date]"
                type="date"
                value={@search.t_date}
                id="search_t_date"
                max={@max_date}
                min={@search.f_date}
              />
            </div>
            <.button class="mt-5 h-10 w-10 grow-0 shrink-0">🔍</.button>
          </div>
        </.form>
      </div>
      <div class="font-medium flex flex-row bg-amber-200">
        <div class="w-[16%] text-center border-b border-t border-amber-400 p-1">
          <%= gettext("UUID / InternalId") %>
        </div>
        <div class="w-[16%] border-b border-t border-amber-400 p-1">
          <%= gettext("Received/Issued/Reject Date") %>
        </div>
        <div class="w-[7%] border-b border-t border-amber-400 p-1">
          <%= gettext("Type / Version") %>
        </div>
        <div class="w-[9%] text-center border-b border-t border-amber-400 p-1">
          <%= gettext("Amount") %>
        </div>
        <div class="w-[15%] border-b border-t border-amber-400 p-1">
          <%= gettext("SupplierName / TIN") %>
        </div>
        <div class="w-[15%] border-b border-t border-amber-400 p-1">
          <%= gettext("BuyerName / TIN") %>
        </div>
        <div class="w-[16%] border-b border-t border-amber-400 p-1">
          <%= gettext("SubmissionID / Channel") %>
        </div>
        <div class="w-[6%] text-center border-b border-t border-amber-400 p-1">
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
        <%= for {obj_id, obj} <- @streams.objects do %>
          <.live_component module={IndexComponent} id={obj_id} obj={obj} company={@current_company} />
        <% end %>
      </div>
      <.infinite_scroll_footer ended={@end_of_timeline?} />
    </div>
    """
  end
end
