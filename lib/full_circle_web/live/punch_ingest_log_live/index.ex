defmodule FullCircleWeb.PunchIngestLogLive.Index do
  @moduledoc """
  Read-only list of every gate POST the server could attribute to this company.

  Punch IO answers "what got recorded"; this answers "what arrived and what the
  server did with it" — including the rejects and revoked-device 401s that
  never reach `time_attendences`. No new/edit/delete, by design.
  """
  use FullCircleWeb, :live_view

  alias FullCircle.Authorization
  alias FullCircle.PunchGate

  @per_page 100

  @impl true
  def render(assigns) do
    ~H"""
    <div id="punchIngestLogIndex" class="mx-auto w-11/12">
      <p class="w-full text-3xl text-center font-medium">{@page_title}</p>
      <div class="flex justify-center mb-2">
        <.form for={%{}} id="search-form" phx-submit="search" autocomplete="off" class="w-full">
          <div class="flex flex-row flex-wrap tracking-tighter text-sm">
            <div class="w-[24%]">
              <.input
                id="search_emp_name"
                name="search[emp_name]"
                type="search"
                value={@search.emp_name}
                label={gettext("Employee or Badge")}
              />
            </div>
            <div class="w-[16%]">
              <.input
                id="search_device_name"
                name="search[device_name]"
                type="search"
                value={@search.device_name}
                label={gettext("Device")}
              />
            </div>
            <div class="w-[15%]">
              <.input
                name="search[sdate]"
                type="date"
                value={@search.sdate}
                id="search_sdate"
                label={gettext("Received From")}
              />
            </div>
            <div class="w-[15%]">
              <.input
                name="search[edate]"
                type="date"
                value={@search.edate}
                id="search_edate"
                label={gettext("Received To")}
              />
            </div>
            <div class="w-[15%]">
              <.input
                name="search[outcome]"
                type="select"
                value={@search.outcome}
                id="search_outcome"
                options={outcome_options()}
                label={gettext("Outcome")}
              />
            </div>
            <div class="w-[10%] flex items-center justify-center mt-5">
              <.input
                id="search_show_photos"
                name="search[show_photos]"
                type="checkbox"
                value={@search.show_photos}
                phx-debounce={nil}
                phx-click={
                  JS.toggle_class("show-punch-photos", to: "#punch_photos_wrapper")
                  |> JS.push("toggle_photos")
                }
                label={gettext("Show photos")}
              />
            </div>
            <.button class="mt-5 h-10 w-10 grow-0 shrink-0">🔍</.button>
          </div>
        </.form>
      </div>

      <%!-- bg-amber-200 alone, exactly like Punch IO. app.css already remaps it
            (`.dark .bg-amber-200 { --color-amber-900 }`), and that unlayered rule
            beats a `dark:` utility, so adding one here would be dead CSS. --%>
      <div class="font-medium flex flex-row text-center tracking-tighter bg-amber-200">
        <div class="w-[17%] border-b border-t border-amber-400 py-1">{gettext("Received At")}</div>
        <div class="w-[17%] border-b border-t border-amber-400 py-1">{gettext("Punch Time")}</div>
        <div class="w-[14%] border-b border-t border-amber-400 py-1">{gettext("Device")}</div>
        <div class="w-[24%] border-b border-t border-amber-400 py-1">{gettext("Employee")}</div>
        <div class="w-[20%] border-b border-t border-amber-400 py-1">{gettext("Outcome")}</div>
        <div class="w-[8%] border-b border-t border-amber-400 py-1">{gettext("Status")}</div>
      </div>

      <div id="punch_photos_wrapper" class={@search.show_photos && "show-punch-photos"}>
        <div
          :if={Enum.count(@streams.objects) > 0 or @page > 1}
          id="objects_list"
          phx-update="stream"
          phx-viewport-bottom={!@end_of_timeline? && "next-page"}
          phx-page-loading
        >
          <div
            :for={{obj_id, obj} <- @streams.objects}
            id={obj_id}
            class="flex flex-row text-center tracking-tighter hover:bg-gray-100 dark:hover:bg-gray-700 border-b border-gray-300 dark:border-gray-600 py-1"
          >
            <div class="w-[17%]">{local_time(obj.inserted_at, @current_company)}</div>
            <div class="w-[17%]">{local_time(obj.punched_at, @current_company)}</div>
            <div class="w-[14%]">{obj.device_name}</div>
            <div class="w-[24%]">
              <span :if={obj.employee_name}>{obj.employee_name}</span>
              <span :if={is_nil(obj.employee_name)} class="text-xs break-all text-gray-500">
                {obj.employee_id_raw}
              </span>
              <img
                :if={photo_src(obj, @current_company)}
                src={photo_src(obj, @current_company)}
                loading="lazy"
                alt={gettext("Punch photo")}
                class="punch-photo mt-0.5 mx-auto w-16 h-16 object-cover rounded border border-gray-400 dark:border-gray-600"
              />
            </div>
            <div class={["w-[20%] font-medium", outcome_class(obj.outcome)]}>
              {outcome_label(obj.outcome)}<span :if={obj.reason}>: {reason_label(obj.reason)}</span>
            </div>
            <div class="w-[8%]">{obj.http_status}</div>
          </div>
        </div>
      </div>

      <.infinite_scroll_footer ended={@end_of_timeline?} />
    </div>
    """
  end

  @impl true
  def mount(params, _session, socket) do
    company = socket.assigns.current_company

    if Authorization.can?(socket.assigns.current_user, :view_punch_ingest_log, company) do
      today =
        DateTime.now!(company.timezone)
        |> DateTime.to_date()
        |> Date.to_iso8601()

      search = %{
        emp_name: params["search"]["emp_name"] || "",
        device_name: params["search"]["device_name"] || "",
        sdate: params["search"]["sdate"] || today,
        edate: params["search"]["edate"] || today,
        outcome: params["search"]["outcome"] || "all",
        show_photos: (params["search"]["show_photos"] || "false") == "true"
      }

      {:ok,
       socket
       |> assign(page_title: gettext("Punch Ingest Log"))
       |> assign(search: search)
       |> filter_objects(true, 1)}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("Not Authorized!"))
       |> push_navigate(to: ~p"/companies/#{company.id}/dashboard")}
    end
  end

  @impl true
  def handle_event("toggle_photos", _, socket) do
    s = socket.assigns.search
    # Visibility is CSS on the wrapper, so the stream keeps its rows and its
    # scroll position and nothing is re-queried.
    {:noreply, assign(socket, search: %{s | show_photos: !s.show_photos})}
  end

  @impl true
  def handle_event("next-page", _, socket) do
    {:noreply, filter_objects(socket, false, socket.assigns.page + 1)}
  end

  @impl true
  def handle_event("search", %{"search" => search}, socket) do
    qry = %{
      "search[emp_name]" => search["emp_name"],
      "search[device_name]" => search["device_name"],
      "search[sdate]" => search["sdate"],
      "search[edate]" => search["edate"],
      "search[outcome]" => search["outcome"],
      "search[show_photos]" => to_string((search["show_photos"] || "false") == "true")
    }

    {:noreply,
     push_navigate(socket,
       to:
         "/companies/#{socket.assigns.current_company.id}/punch_ingest_logs?#{URI.encode_query(qry)}"
     )}
  end

  defp filter_objects(socket, reset, page) do
    s = socket.assigns.search

    objects =
      if s.sdate == "" or s.edate == "" do
        []
      else
        PunchGate.list_ingest_logs(
          socket.assigns.current_company,
          socket.assigns.current_user,
          emp_name: s.emp_name,
          device_name: s.device_name,
          sdate: s.sdate,
          edate: s.edate,
          outcome: s.outcome,
          page: page,
          per_page: @per_page
        )
      end

    socket
    |> assign(page: page, per_page: @per_page)
    |> stream(:objects, objects, reset: reset)
    |> assign(end_of_timeline?: Enum.count(objects) < @per_page)
  end

  defp outcome_options do
    [
      {gettext("All"), "all"},
      {gettext("Accepted"), "accepted"},
      {gettext("Replayed"), "replayed"},
      {gettext("Duplicate"), "duplicate"},
      {gettext("Rejected"), "rejected"}
    ]
  end

  defp outcome_label("accepted"), do: gettext("Accepted")
  defp outcome_label("replayed"), do: gettext("Replayed")
  defp outcome_label("duplicate"), do: gettext("Duplicate")
  defp outcome_label("rejected"), do: gettext("Rejected")
  defp outcome_label(other), do: other

  defp outcome_class("accepted"), do: "text-green-700 dark:text-green-400"
  defp outcome_class("replayed"), do: "text-blue-700 dark:text-blue-400"
  defp outcome_class("duplicate"), do: "text-amber-700 dark:text-amber-400"
  defp outcome_class(_), do: "text-rose-700 dark:text-rose-400"

  defp reason_label("not_found"), do: gettext("Unknown Badge")
  defp reason_label("inactive"), do: gettext("Not Active")
  defp reason_label("too_large"), do: gettext("Photo Too Large")
  defp reason_label("missing_photo"), do: gettext("No Photo")
  defp reason_label("future"), do: gettext("Future Time")
  defp reason_label("invalid"), do: gettext("Invalid")
  defp reason_label("revoked"), do: gettext("Device Revoked")
  defp reason_label(other), do: other

  defp photo_src(%{photo_path: path, id: id}, company) when is_binary(path),
    do: ~p"/companies/#{company.id}/punch_ingest_logs/#{id}/photo"

  defp photo_src(%{time_attendence_id: ta_id}, company) when is_binary(ta_id),
    do: ~p"/companies/#{company.id}/TimeAttend/#{ta_id}/photo"

  defp photo_src(_obj, _company), do: nil

  defp local_time(nil, _company), do: ""

  defp local_time(%DateTime{} = dt, company) do
    dt
    |> DateTime.shift_zone!(company.timezone)
    |> Calendar.strftime("%d-%m-%Y %H:%M:%S")
  end
end
