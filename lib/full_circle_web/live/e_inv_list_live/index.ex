defmodule FullCircleWeb.EInvListLive.Index do
  use FullCircleWeb, :live_view
  import Ecto.Query, warn: false

  alias FullCircleWeb.EInvListLive.{IndexReceivedComponent, IndexSentComponent}
  alias FullCircle.EInvMetas
  alias Phoenix.PubSub

  @per_page 15

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      PubSub.subscribe(
        FullCircle.PubSub,
        "#{socket.assigns.current_company.id}_e_invoice_sync_status"
      )
    end

    socket =
      socket
      |> assign(update_action: "stream")
      |> assign(syncing: false)
      |> stream_configure(:objects, dom_id: & &1.uuid)
      |> assign(page_title: gettext("E-Invoices Listing"))
      |> assign(
        last_sync_datetime:
          EInvMetas.e_invoice_last_sync_datetime(
            socket.assigns.current_company,
            socket.assigns.current_user
          )
      )

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    params = params["search"]

    terms = params["terms"] || ""
    direction = params["direction"] || "Received"

    f_date =
      params["f_date"] ||
        DateTime.now!(socket.assigns.current_company.timezone)
        |> DateTime.add(-10, :day)
        |> DateTime.to_iso8601()

    t_date =
      params["t_date"] ||
        DateTime.now!(socket.assigns.current_company.timezone) |> DateTime.to_iso8601()

    socket =
      socket
      |> assign(
        search: %{
          f_date: f_date,
          t_date: t_date,
          terms: terms,
          direction: direction
        }
      )

    {:noreply, socket |> assign(update_action: "stream") |> filter_objects(true, 1)}
  end

  @impl true
  def handle_event("next-page", _, socket) do
    {:noreply, socket |> filter_objects(false, socket.assigns.page + 1)}
  end

  @impl true
  def handle_event(
        "search",
        %{
          "search" => %{
            "f_date" => f_date,
            "t_date" => t_date,
            "terms" => terms,
            "direction" => direction
          }
        },
        socket
      ) do
    qry = %{
      "search[f_date]" => f_date,
      "search[t_date]" => t_date,
      "search[terms]" => terms,
      "search[direction]" => direction
    }

    url = "/companies/#{socket.assigns.current_company.id}/e_invoices?#{URI.encode_query(qry)}"

    {:noreply, socket |> push_navigate(to: url)}
  end

  @impl true
  def handle_event("sync", _, socket) do
    pid = self()

    Task.async(fn ->
      EInvMetas.sync_e_invoices(socket.assigns.current_company, socket.assigns.current_user)
      send(pid, :finished_sync)
    end)

    {:noreply,
     socket |> assign(syncing: true) |> assign(sd: "") |> assign(ed: "") |> assign(page: "")}
  end

  @impl true
  def handle_info(:finished_sync, socket) do
    {:noreply,
     socket
     |> assign(update_action: "stream")
     |> assign(syncing: false)
     |> assign(
       last_sync_datetime:
         EInvMetas.e_invoice_last_sync_datetime(
           socket.assigns.current_company,
           socket.assigns.current_user
         )
     )
     |> filter_objects(true, 1)}
  end

  @impl true
  def handle_info({:update_sync_status, sd, ed, page}, socket) do
    {:noreply,
     socket
     |> assign(sd: String.slice(sd, 0..9))
     |> assign(ed: String.slice(ed, 0..9))
     |> assign(page: page)}
  end

  @impl true
  def handle_info(_, socket) do
    {:noreply, socket}
  end

  defp filter_objects(socket, reset, page) when page >= 1 do
    objects =
      EInvMetas.get_e_invoices(
        socket.assigns.search.f_date
        |> Timex.parse!("{ISO:Extended}")
        |> Timex.to_datetime(:utc),
        socket.assigns.search.t_date
        |> Timex.parse!("{ISO:Extended}")
        |> Timex.to_datetime(:utc),
        @per_page,
        page,
        socket.assigns.current_company,
        socket.assigns.current_user,
        socket.assigns.search.direction,
        socket.assigns.search.terms
      )

    preloaded_objects = Task.async_stream(objects, fn obj ->
      direction = if obj.issuerTIN == socket.assigns.current_company.tax_id, do: "Sent", else: "Received"

      fc_docs = EInvMetas.get_internal_document(obj.typeName, direction, obj, socket.assigns.current_company)

      Map.put(obj, :fc_docs, fc_docs)
    end) |> Enum.map(fn {:ok, obj} -> obj end)

    socket
    |> assign(page: page)
    |> stream(:objects, preloaded_objects, reset: reset)
    |> assign(end_of_timeline?: Enum.count(preloaded_objects) < @per_page)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto w-10/12">
      <p class="w-full text-3xl text-center font-medium">{@page_title}</p>
      <div class="mt-4 mb-5 flex justify-center">
        <div class="">
          <%= if @syncing do %>
            <div class="text-lg red button" id="syncing">
              {gettext("Syncing E-Invoice ")}{"#{@sd} - #{@ed} page #{@page}"}...
              <.icon name="hero-arrow-path" class="ml-1 h-3 w-3 animate-spin" />
            </div>
          <% else %>
            <.link phx-click="sync" class="text-lg blue button" id="sync">
              {gettext("Last Sync at")} {@last_sync_datetime
              |> Timex.local()
              |> FullCircleWeb.Helpers.format_datetime(@current_company)}
              <span class="font-semibold text-green-600">
                {gettext("Click here to Sync E-Invoice again")}
              </span>
            </.link>
          <% end %>
        </div>
      </div>
      <div class="flex justify-center mb-2">
        <.form for={%{}} id="search-form" phx-submit="search" autocomplete="off" class="w-full">
          <div class=" flex flex-row flex-wrap tracking-tighter text-sm">
            <div class="w-[10rem] grow-0 shrink-0">
              <label>Received Date From</label>
              <.input
                name="search[f_date]"
                type="datetime-local"
                value={@search.f_date |> Timex.parse!("{ISO:Extended}")}
                id="search_f_date"
              />
            </div>
            <div class="w-[10rem] grow-0 shrink-0">
              <label>Received Date To</label>
              <.input
                name="search[t_date]"
                type="datetime-local"
                value={@search.t_date |> Timex.parse!("{ISO:Extended}")}
                id="search_t_date"
              />
            </div>
            <div class="w-[6rem] grow-0 shrink-0">
              <label>Direction</label>
              <.input
                name="search[direction]"
                type="select"
                options={["Received", "Sent"]}
                value={@search.direction}
                id="search_direction"
              />
            </div>
            <div class="w-[21rem] grow-0 shrink-0">
              <label>Terms</label>
              <.input
                name="search[terms]"
                placeholder="uuid, internal id, contact, type or tin..."
                type="text"
                value={@search.terms}
                id="search_contact"
              />
            </div>
            <.button class="mt-4 h-10 w-10 grow-0 shrink-0">🔍</.button>
          </div>
        </.form>
      </div>
      <div class="flex flex-row">
        <div class="font-medium flex flex-row bg-amber-200 w-[49.8%]">
          <div class="w-[22%] border-b border-t border-amber-400 p-1">
            <div>{gettext("Received/ Issued/ Reject")}</div>
          </div>
          <div class="w-[36%] border-b border-t border-amber-400 p-1">
            <div>{gettext("UUD/ InternalId/ Direction/ Type")}</div>
          </div>
          <div class="w-[42%] border-b border-t border-amber-400 p-1">
            <div>{gettext("ContactName/ TIN/ NetAmount/ PayaAmount")}</div>
          </div>
        </div>
        <div class="w-[0.4%] bg-white"></div>
        <div class="font-medium flex flex-row bg-cyan-200 w-[49.8%]">
          <div class="w-[22%] border-b border-t border-amber-400 p-1">
            <div>{gettext("Doc Date")}</div>
          </div>
          <div class="w-[36%] border-b border-t border-amber-400 p-1">
            <div>{gettext("InternalId/ Type")}</div>
          </div>
          <div class="w-[42%] border-b border-t border-amber-400 p-1">
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
            :if={obj.issuerTIN != @current_company.tax_id}
            module={IndexReceivedComponent}
            id={obj_id}
            obj={obj}
            company={@current_company}
            user={@current_user}
          />
          <.live_component
            :if={obj.issuerTIN == @current_company.tax_id}
            module={IndexSentComponent}
            id={obj_id}
            obj={obj}
            company={@current_company}
            user={@current_user}
          />
        <% end %>
      </div>
      <.infinite_scroll_footer ended={@end_of_timeline?} />
    </div>
    """
  end
end
