defmodule FullCircleWeb.UploadPunchLog.Index do
  use FullCircleWeb, :live_view

  alias FullCircle.HR

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(page_title: gettext("Time Attendence Import"))
      |> allow_upload(:xlsx_file,
        accept: ~w(.xlsx),
        max_entries: 4,
        max_file_size: 12_000_000,
        auto_upload: true,
        progress: &handle_progress/3
      )
      |> assign(
        people: [],
        all_employees: [],
        attendances: [],
        raw_attendances: [],
        total_employees: 0,
        total_attendence_entries: 0,
        from_date: "NA",
        to_date: "NA",
        filename: "NA",
        imported: false,
        import_result: nil
      )

    {:ok, socket}
  end

  @impl true
  def handle_event("cancel-upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :xlsx_file, ref)}
  end

  @impl true
  def handle_event("import", _params, socket) do
    case insert_time_attendence_from_logs(
           socket.assigns.attendances,
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      :not_authorise ->
        {:noreply,
         socket |> put_flash(:error, gettext("You are not authorised to import attendance."))}

      result ->
        {:noreply,
         socket
         |> assign(imported: true, import_result: result)
         |> put_flash(
           :info,
           gettext("Imported %{n} new punches for %{e} employees.",
             n: result.total_inserted,
             e: Enum.count(result.employees)
           )
         )}
    end
  end

  @impl true
  def handle_event("upload", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("refresh", _params, socket) do
    case FullCircle.HR.FingerPrintImport.parse_files_rows(socket.assigns.raw_attendances) do
      {:ok, raw_attendances} ->
        {:noreply,
         build_attendances_assigns(socket, socket.assigns.raw_attendances, raw_attendances)}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("validate", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("confirm_match", %{"card-id" => card_id, "emp-id" => emp_id}, socket) do
    {:noreply, do_match(socket, card_id, emp_id)}
  end

  @impl true
  def handle_event("manual_match", %{"card_id" => card_id, "employee_id" => emp_id}, socket)
      when emp_id != "" do
    {:noreply, do_match(socket, card_id, emp_id)}
  end

  def handle_event("manual_match", _params, socket), do: {:noreply, socket}

  def handle_progress(:xlsx_file, _entry, socket) do
    {_done, still_uploading} = uploaded_entries(socket, :xlsx_file)

    if still_uploading == [] do
      results =
        consume_uploaded_entries(socket, :xlsx_file, fn %{path: path}, _entry ->
          {:ok, read_excel_files(path)}
        end)

      if Enum.any?(results, &match?({:error, _}, &1)) do
        {:noreply,
         socket
         |> put_flash(
           :error,
           gettext(
             "A file could not be read — make sure it is a fingerprint 'Att.log report' export."
           )
         )}
      else
        raw_files = Enum.map(results, fn {:ok, rows} -> rows end)
        handle_parsed_files(socket, raw_files)
      end
    else
      {:noreply, socket}
    end
  end

  defp handle_parsed_files(socket, raw_files) do
    case FullCircle.HR.FingerPrintImport.parse_files_rows(raw_files) do
      {:ok, []} ->
        {:noreply, socket |> put_flash(:error, gettext("No punches found in the file(s)."))}

      {:ok, raw_attendances} ->
        {:noreply, build_attendances_assigns(socket, raw_files, raw_attendances)}

      {:error, {:date_range_mismatch, _ranges}} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           gettext("Uploaded files cover different months. Upload one month's machines together.")
         )}
    end
  end

  defp build_attendances_assigns(socket, raw_files, raw_attendances) do
    com = socket.assigns.current_company
    user = socket.assigns.current_user

    attendances = fill_in_employee_info(raw_attendances, com, user)

    people = build_people(attendances, com, user)
    todate = attendances |> Enum.max_by(& &1.punch_time_local) |> Map.get(:punch_time_local)
    fromdate = attendances |> Enum.min_by(& &1.punch_time_local) |> Map.get(:punch_time_local)

    socket
    |> assign(
      raw_attendances: raw_files,
      attendances: attendances,
      people: people,
      all_employees: HR.match_employee_candidates("", com, user, 10_000),
      total_attendence_entries: Enum.count(attendances),
      total_employees: Enum.count(people),
      from_date: Timex.to_date(fromdate),
      to_date: Timex.to_date(todate),
      imported: false,
      import_result: nil
    )
  end

  # One row per distinct fingerprint person that has >= 1 punch.
  defp build_people(attendances, com, user) do
    attendances
    |> Enum.group_by(& &1.punch_card_id)
    |> Enum.map(fn {card_id, list} ->
      first = hd(list)
      matched? = first.employee_id != "!! Not Found !!"

      %{
        punch_card_id: card_id,
        finger_name: first[:Name],
        punch_count: Enum.count(list),
        employee_id: if(matched?, do: first.employee_id, else: nil),
        employee_name: if(matched?, do: first.employee_name, else: nil),
        candidates:
          if(matched?, do: [], else: HR.match_employee_candidates(first[:Name], com, user, 3))
      }
    end)
    |> Enum.sort_by(& &1.finger_name)
  end

  defp do_match(socket, card_id, emp_id) do
    com = socket.assigns.current_company
    user = socket.assigns.current_user

    case HR.set_employee_punch_card_id(emp_id, card_id, com, user) do
      {:ok, _emp} ->
        attendances = fill_in_employee_info(socket.assigns.attendances, com, user)

        socket
        |> assign(
          attendances: attendances,
          people: build_people(attendances, com, user)
        )

      _ ->
        socket |> put_flash(:error, gettext("Could not match employee."))
    end
  end

  # Inserts matched, flagged punches and returns a per-employee tally:
  # %{employees: [%{name, inserted, skipped}], unmatched: [name], total_inserted, total_skipped}.
  # insert_time_attendence_from_log/2 returns {:ok, _} on a real insert and nil when it
  # skips an already-present punch (±5-min idempotency), so we count {:ok, _} as inserted.
  defp insert_time_attendence_from_logs(entries, com, user) do
    case FullCircle.Authorization.can?(user, :create_time_attendence, com) do
      true ->
        {matched, unmatched} =
          Enum.split_with(entries, fn x -> x.employee_id != "!! Not Found !!" end)

        employees =
          matched
          # skip flag-less punches (a rare 7th+ daily punch gets flag: nil, which fails
          # the TimeAttend changeset's required-flag check)
          |> Enum.reject(fn x -> is_nil(x.flag) end)
          |> Enum.group_by(fn x -> x.employee_name end)
          |> Enum.map(fn {name, list} ->
            inserted =
              list
              |> Enum.map(fn x -> HR.insert_time_attendence_from_log(x, com) end)
              |> Enum.count(&match?({:ok, _}, &1))

            %{name: name, inserted: inserted, skipped: Enum.count(list) - inserted}
          end)
          |> Enum.sort_by(& &1.name)

        %{
          employees: employees,
          unmatched: unmatched |> Enum.map(fn x -> x[:Name] end) |> Enum.uniq() |> Enum.sort(),
          total_inserted: Enum.sum(Enum.map(employees, & &1.inserted)),
          total_skipped: Enum.sum(Enum.map(employees, & &1.skipped))
        }

      false ->
        :not_authorise
    end
  end

  defp error_to_string(:too_large), do: "Too large!"
  defp error_to_string(:too_many_files), do: "You have selected too many files!"
  defp error_to_string(:not_accepted), do: "You have selected an unacceptable file type"

  def read_excel_files(file) do
    with {:ok, package} <- XlsxReader.open(File.read!(file), source: :binary),
         {:ok, rows} <- XlsxReader.sheet(package, "Att.log report") do
      {:ok, rows}
    else
      _ -> {:error, :unreadable}
    end
  end

  def fill_in_employee_info(res, com, user) do
    emps =
      Enum.uniq_by(res, fn x -> x.punch_card_id end)
      |> Enum.map(fn x -> x.punch_card_id end)
      |> HR.get_employees_by_punch_card_ids(com, user)

    Enum.map(res, fn x ->
      emp =
        Enum.find(emps, fn q -> q.punch_card_id == x.punch_card_id end) ||
          %{id: "!! Not Found !!", name: x.punch_card_id}

      Map.merge(x, %{
        employee_id: emp.id,
        employee_name: emp.name,
        company_id: com.id,
        user_id: user.id,
        input_medium: "finger_log",
        punch_time:
          x.punch_time_local |> Timex.to_datetime(com.timezone) |> Timex.to_datetime(:utc)
      })
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="w-10/12 mx-auto">
      <p class="w-full text-3xl text-center font-medium">{@page_title}</p>
      <.form
        for={%{}}
        id="object-form"
        autocomplete="off"
        phx-submit="upload"
        phx-change="validate"
        class="p-4 mb-1 border rounded-lg border-blue-500 bg-blue-200"
      >
        {"Maximum file size is #{@uploads.xlsx_file.max_file_size / 1_000_000} MB"}

        <input
          type="file"
          id="xls-picker"
          name="xls-picker"
          accept=".xls,.xlsx"
          multiple
          phx-hook="XlsToXlsxUpload"
          phx-update="ignore"
        />
        <%!-- Hidden real upload input: the XlsToXlsxUpload hook converts the picked
              .xls to .xlsx in-browser and feeds it here via this.upload("xlsx_file", ...).
              LiveView's programmatic upload requires this live_file_input to exist. --%>
        <.live_file_input upload={@uploads.xlsx_file} class="hidden" />
        <div phx-drop-target={@uploads.xlsx_file.ref} class="p-2">
          <%= for entry <- @uploads.xlsx_file.entries do %>
            <div class="mt-2 gap-2 flex flex-row tracking-tighter border-2 border-green-600 place-items-center p-2 rounded-lg">
              <div class="w-[40%]">{entry.client_name}</div>
              <div class="w-[10%] border">
                {DateTime.from_unix!(entry.client_last_modified, :milliseconds)
                |> FullCircleWeb.Helpers.format_datetime(@current_company)}
              </div>
              <div class="w-[50%] text-right">
                <progress class="mt-1" value={entry.progress} max="100">
                  {entry.progress}
                </progress>
                <.link
                  phx-click="cancel-upload"
                  phx-value-ref={entry.ref}
                  class="font-bold text-orange-600"
                >
                  X
                </.link>
                <%= for err <- upload_errors(@uploads.xlsx_file, entry) do %>
                  <div class="text-center text-rose-600">
                    {error_to_string(err)}
                  </div>
                <% end %>
              </div>
            </div>
          <% end %>

          <%= for err <- upload_errors(@uploads.xlsx_file) do %>
            <p class="w-[50%] mx-auto text-rose-600 border-4 font-bold rounded p-4 border-rose-700 bg-rose-200">
              {error_to_string(err)}
            </p>
          <% end %>
        </div>
      </.form>
    </div>
    <div class="w-10/12 mx-auto flex p-4 mb-1 border rounded-lg border-orange-500 bg-orange-200">
      <div class="w-[34%]">
        <span class="text-xl">File: </span><span class="text-xl font-bold">{@filename}</span>
      </div>
      <div class="w-[18%]">
        <span class="text-xl">Total Employee: </span><span class="text-xl font-bold">{@total_employees}</span>
      </div>
      <div class="w-[18%]">
        <span class="text-xl">Total Entries: </span><span class="text-xl font-bold">{@total_attendence_entries}</span>
      </div>
      <div class="w-[15%]">
        <span class="text-xl">From: </span><span class="text-xl font-bold">{@from_date}</span>
      </div>
      <div class="w-[15%]">
        <span class="text-xl">To: </span><span class="text-xl font-bold">{@to_date}</span>
      </div>
    </div>
    <div
      :if={!@imported}
      class="w-10/12 mx-auto p-4 mb-1 border rounded-lg border-green-500 bg-green-200"
    >
      <div class="my-2 text-center mx-auto font-bold text-2xl">
        <.link phx-click="refresh" class="button blue">{gettext("Refresh")}</.link>
      </div>

      <%= for person <- @people do %>
        <div class={"m-1 p-2 border rounded flex flex-wrap items-center gap-2 " <>
              if(person.employee_id, do: "bg-green-100 border-green-500",
                 else: "bg-rose-200 border-rose-400")}>
          <div class="w-[28%] font-bold">
            {person.finger_name}
            <span class="font-normal text-sm">({person.punch_count} {gettext("punches")})</span>
          </div>

          <%= if person.employee_id do %>
            <div class="text-green-800">✓ {person.employee_name}</div>
          <% else %>
            <div class="flex flex-wrap items-center gap-1">
              <%= for cand <- person.candidates do %>
                <button
                  type="button"
                  phx-click="confirm_match"
                  phx-value-card-id={person.punch_card_id}
                  phx-value-emp-id={cand.id}
                  class="button orange"
                >
                  {cand.name}
                  <span :if={cand.status != "Active"} class="text-xs">({cand.status})</span>
                </button>
              <% end %>

              <form phx-change="manual_match" class="inline">
                <input type="hidden" name="card_id" value={person.punch_card_id} />
                <select name="employee_id" class="border rounded p-1">
                  <option value="">{gettext("— pick manually —")}</option>
                  <%= for e <- @all_employees do %>
                    <option value={e.id}>{e.name}</option>
                  <% end %>
                </select>
              </form>
            </div>
          <% end %>
        </div>
      <% end %>
    </div>
    <div :if={!@imported} class="mt-3 text-center mx-auto font-bold text-2xl mb-10">
      <.link :if={Enum.count(@people) > 0} phx-click="import" class="button blue">Import</.link>
    </div>

    <div
      :if={@imported and is_map(@import_result)}
      class="w-10/12 mx-auto p-4 mb-1 border rounded-lg border-green-500 bg-green-200"
    >
      <p class="text-2xl font-bold text-center mb-1">{gettext("Import complete")}</p>
      <p class="text-center mb-3">
        {gettext("Inserted")}
        <span class="font-bold">{@import_result.total_inserted}</span>
        {gettext("new punches for")}
        <span class="font-bold">{Enum.count(@import_result.employees)}</span>
        {gettext("employees")} · <span class="font-bold">{@import_result.total_skipped}</span>
        {gettext("already present (skipped)")}
      </p>

      <%= for e <- @import_result.employees do %>
        <div class="m-1 p-2 border rounded bg-green-100 border-green-500 flex flex-wrap items-center gap-3">
          <div class="w-[45%] font-bold">{e.name}</div>
          <div class="text-green-800 font-bold">+{e.inserted} {gettext("new")}</div>
          <div :if={e.skipped > 0}>{e.skipped} {gettext("skipped")}</div>
        </div>
      <% end %>

      <div
        :if={@import_result.unmatched != []}
        class="mt-3 p-2 border rounded bg-rose-200 border-rose-400"
      >
        <p class="font-bold">{gettext("Not imported — unmatched")}:</p>
        <p>{Enum.join(@import_result.unmatched, ", ")}</p>
      </div>
    </div>
    """
  end
end
