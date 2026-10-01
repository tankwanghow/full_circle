defmodule FullCircleWeb.EInvListLive.Index do
  use FullCircleWeb, :live_view
  import Ecto.Query, warn: false
  import FullCircleWeb.ListComponents

  alias FullCircleWeb.EInvListLive.IndexComponent
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
      |> assign(sync_status: "")
      |> stream_configure(:objects, dom_id: & &1.uuid)
      |> assign(page_title: gettext("E-Invoices"))
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
    com = socket.assigns.current_company
    user = socket.assigns.current_user

    # try/rescue keeps the linked Task.async from propagating a crash to this
    # LiveView — any failure comes back as {:finished_sync, {:error, msg}}.
    Task.async(fn ->
      result =
        try do
          EInvMetas.sync_e_invoices(com, user)
        rescue
          e -> {:error, Exception.message(e)}
        catch
          kind, reason -> {:error, "#{kind}: #{inspect(reason)}"}
        end

      send(pid, {:finished_sync, result})
    end)

    {:noreply, socket |> assign(syncing: true) |> assign(sync_status: gettext("starting…"))}
  end

  @impl true
  def handle_info({:finished_sync, result}, socket) do
    socket =
      case result do
        {:error, msg} ->
          put_flash(socket, :error, gettext("E-Invoice sync stopped: ") <> msg)

        {:ok, 0} ->
          put_flash(socket, :info, gettext("E-Invoice sync complete — no new invoices."))

        {:ok, n} ->
          put_flash(
            socket,
            :info,
            gettext("E-Invoice sync complete — %{count} new invoice(s).", count: n)
          )

        _ ->
          socket
      end

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
  def handle_info({:sync_status, text}, socket) do
    {:noreply, assign(socket, sync_status: text)}
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

    preloaded_objects =
      Task.async_stream(objects, fn obj ->
        direction =
          if obj.issuerTIN == socket.assigns.current_company.tax_id, do: "Sent", else: "Received"

        fc_docs =
          EInvMetas.get_internal_document(
            obj.typeName,
            direction,
            obj,
            socket.assigns.current_company
          )

        Map.put(obj, :fc_docs, fc_docs)
      end)
      |> Enum.map(fn {:ok, obj} -> obj end)

    socket
    |> assign(page: page)
    |> stream(:objects, preloaded_objects, reset: reset)
    |> assign(end_of_timeline?: Enum.count(preloaded_objects) < @per_page)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto w-11/12 max-w-[96rem]">
      <.form for={%{}} id="search-form" phx-submit="search" autocomplete="off">
        <.list_bar title={@page_title}>
          <div class="grow min-w-56">
            <.filter_label>{gettext("Search")}</.filter_label>
            <.input
              name="search[terms]"
              type="search"
              placeholder={gettext("uuid, doc no, contact, type or TIN…")}
              value={@search.terms}
              id="search_contact"
            />
          </div>
          <div class="w-28">
            <.filter_label>{gettext("Direction")}</.filter_label>
            <.input
              name="search[direction]"
              type="select"
              options={["Received", "Sent"]}
              value={@search.direction}
              id="search_direction"
            />
          </div>
          <div class="w-48">
            <.filter_label>{gettext("Received from")}</.filter_label>
            <.input
              name="search[f_date]"
              type="datetime-local"
              value={@search.f_date |> Timex.parse!("{ISO:Extended}")}
              id="search_f_date"
            />
          </div>
          <div class="w-48">
            <.filter_label>{gettext("Received to")}</.filter_label>
            <.input
              name="search[t_date]"
              type="datetime-local"
              value={@search.t_date |> Timex.parse!("{ISO:Extended}")}
              id="search_t_date"
            />
          </div>
          <.button class="h-9 w-10">🔍</.button>
          <:actions>
            <.link
              navigate={~p"/companies/#{@current_company.id}/e_invoice_queue"}
              class="gray button"
            >
              {gettext("Received work queue")}
            </.link>
            <button
              :if={!@syncing}
              type="button"
              phx-click="sync"
              id="sync"
              class="blue button"
              title={gettext("Fetch new e-invoices from MyInvois")}
            >
              ↻ {gettext("Sync")}
              <span class="text-xs opacity-75">
                {gettext("last")} {@last_sync_datetime
                |> FullCircleWeb.Helpers.format_datetime(@current_company)}
              </span>
            </button>
            <button :if={@syncing} type="button" class="blue button" disabled>
              <.icon name="hero-arrow-path" class="h-4 w-4 animate-spin" /> {gettext("Syncing…")}
            </button>
          </:actions>
        </.list_bar>
      </.form>

      <div
        :if={@syncing}
        id="syncing"
        class="mb-3 flex items-center gap-2 rounded border border-amber-300/70 bg-amber-100/80 px-3 py-1.5 text-sm text-amber-900 dark:border-amber-700/60 dark:bg-amber-900/40 dark:text-amber-200"
      >
        <.icon name="hero-arrow-path" class="h-4 w-4 animate-spin" />
        {gettext("Syncing E-Invoice")} {@sync_status}
      </div>

      <.list_table>
        <:head>
          <div class="w-36 shrink-0">{gettext("Received")}</div>
          <div class="w-40 shrink-0">{gettext("Doc No.")}</div>
          <div class="w-32 shrink-0">{gettext("Type")}</div>
          <div class="flex-1 min-w-0">
            {if @search.direction == "Sent", do: gettext("Buyer"), else: gettext("Supplier")}
          </div>
          <div class="w-32 shrink-0 text-right">{gettext("Amount")}</div>
          <div class="w-20 shrink-0">{gettext("Status")}</div>
          <div class="w-80 shrink-0">{gettext("Full Circle")}</div>
        </:head>
        <div id="objects_list" phx-update="stream" phx-page-loading>
          <div id="objects_empty" class="hidden only:block p-4 text-sm text-slate-500">
            {gettext("No e-invoices in this period.")}
          </div>
          <.live_component
            :for={{obj_id, obj} <- @streams.objects}
            module={IndexComponent}
            id={obj_id}
            obj={obj}
            direction={if obj.issuerTIN == @current_company.tax_id, do: "Sent", else: "Received"}
            company={@current_company}
            user={@current_user}
            einv_portal={@einv_portal}
          />
        </div>
      </.list_table>
      <.infinite_scroll_footer ended={@end_of_timeline?} />
    </div>
    """
  end
end
