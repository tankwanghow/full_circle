defmodule FullCircleWeb.TimeAttendLive.Index do
  use FullCircleWeb, :live_view

  alias FullCircle.HR
  alias FullCircleWeb.TimeAttendLive.IndexComponent

  @per_page 60

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto w-10/12">
      <p class="w-full text-3xl text-center font-medium">{@page_title}</p>
      <div class="flex justify-center mb-2">
        <.form for={%{}} id="search-form" phx-submit="search" autocomplete="off" class="w-full">
          <div class=" flex flex-row flex-wrap tracking-tighter text-sm">
            <div class="w-[13rem] grow shrink">
              <label class="">Search Terms</label>
              <.input
                id="search_terms"
                name="search[terms]"
                type="search"
                value={@search.terms}
                placeholder="employee, flag or input medium..."
              />
            </div>
            <div class="w-[12rem] grow-0 shrink-0">
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
        <.link phx-click={:new_timeattend} class="blue button" id="new_timeattend">
          {gettext("New Time Attendence")}
        </.link>
      </div>
      <div class="font-medium flex flex-row text-center tracking-tighter bg-amber-200">
        <div class="w-[30%] border-b border-t border-amber-400 py-1">
          {gettext("Employee")}
        </div>
        <div class="w-[15%] border-b border-t border-amber-400 py-1">
          {gettext("Punch Date Time")}
        </div>
        <div class="w-[10%] border-b border-t border-amber-400 py-1">
          {gettext("IN/OUT")}
        </div>
        <div class="w-[15%] border-b border-t border-amber-400 py-1">
          {gettext("Medium")}
        </div>
        <div class="w-[15%] border-b border-t border-amber-400 py-1">
          {gettext("Touch By")}
        </div>
        <div class="w-[15%] border-b border-t border-amber-400 py-1">
          {gettext("Touch At")}
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

    <.modal
      :if={@live_action in [:new, :edit]}
      id="timeattend-modal"
      show
      on_cancel={JS.push("modal_cancel")}
      max_w="max-w-5xl"
    >
      <.live_component
        module={FullCircleWeb.TimeAttendLive.FormComponent}
        live_action={@live_action}
        id={@obj.id || :new}
        obj={@obj}
        title={@title}
        action={@live_action}
        current_company={@current_company}
        current_user={@current_user}
        created_info={:created}
        updated_info={:updated}
        deleted_info={:deleted}
        error_info={:error}
      />
    </.modal>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(page_title: gettext("Punch RAW Listing"))
      |> assign(search: %{terms: "", punch_date: ""})
      |> filter_objects("", true, "", 1)

    {:ok, socket}
  end

  @impl true
  def handle_event("next-page", _, socket) do
    {:noreply,
     socket
     |> filter_objects(
       socket.assigns.search.terms,
       false,
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
            "punch_date" => pd
          }
        },
        socket
      ) do
    {:noreply,
     socket
     |> assign(search: %{terms: terms, punch_date: pd})
     |> filter_objects(terms, true, pd, 1)}
  end

  @impl true
  def handle_event("new_timeattend", _, socket) do
    {:noreply,
     socket
     |> assign(live_action: :new)
     |> assign(obj: %FullCircle.HR.TimeAttend{})
     |> assign(title: gettext("New Attendence"))}
  end

  @impl true
  def handle_event("edit_timeattend", params, socket) do
    ta =
      HR.get_time_attendence!(
        params["id"],
        socket.assigns.current_company,
        socket.assigns.current_user
      )

    {:noreply,
     socket
     |> assign(live_action: :edit)
     |> assign(obj: ta)
     |> assign(title: gettext("Edit Attendence"))}
  end

  @impl true
  def handle_event("modal_cancel", _, socket) do
    {:noreply, socket |> assign(live_action: nil)}
  end

  @impl true
  def handle_info({:deleted, obj}, socket) do
    send_update(self(), FullCircleWeb.TimeAttendLive.IndexComponent,
      id: "objects-#{obj.id}",
      ex_class: "hidden"
    )

    {:noreply,
     socket
     |> assign(live_action: nil)
     |> put_flash(:success, "#{gettext("Deleted!!")}")}
  end

  @impl true
  def handle_info({:created, obj}, socket) do
    obj =
      HR.get_time_attendence!(
        obj.id,
        socket.assigns.current_company,
        socket.assigns.current_user
      )

    send_update_after(
      self(),
      FullCircleWeb.TimeAttendLive.IndexComponent,
      [id: "objects-#{obj.id}", obj: obj, ex_class: "shake"],
      1000
    )

    send_update_after(
      self(),
      FullCircleWeb.TimeAttendLive.IndexComponent,
      [id: "objects-#{obj.id}", obj: obj, ex_class: ""],
      2000
    )

    {:noreply,
     socket
     |> assign(live_action: nil)
     |> stream_insert(:objects, obj, at: 0)}
  end

  @impl true
  def handle_info({:updated, obj}, socket) do
    obj =
      HR.get_time_attendence!(
        obj.id,
        socket.assigns.current_company,
        socket.assigns.current_user
      )

    send_update(self(), FullCircleWeb.TimeAttendLive.IndexComponent,
      id: "objects-#{obj.id}",
      obj: obj,
      ex_class: "shake"
    )

    send_update_after(
      self(),
      FullCircleWeb.TimeAttendLive.IndexComponent,
      [id: "objects-#{obj.id}", obj: obj, ex_class: ""],
      1000
    )

    {:noreply, socket |> assign(live_action: nil)}
  end

  defp filter_objects(socket, terms, reset, punch_date, page) do
    punch_date =
      if punch_date == "" do
        ""
      else
        "#{punch_date} 00:00"
        |> Timex.parse!("{RFC3339}")
        |> Timex.to_datetime(socket.assigns.current_company.timezone)
        |> Timex.to_datetime(:utc)
      end

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
    |> stream(:objects, objects, reset: reset)
    |> assign(end_of_timeline?: obj_count < @per_page)
  end
end
