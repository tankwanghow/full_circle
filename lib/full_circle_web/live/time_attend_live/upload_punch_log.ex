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
        max_file_size: 6_000_000,
        auto_upload: true,
        progress: &handle_progress/3
      )
      |> assign(
        employees: [],
        attendences: [],
        total_employees: 0,
        total_attendence_entries: 0,
        from_date: "NA",
        to_date: "NA",
        filename: "NA",
        imported: false,
        raw_attendences: []
      )

    {:ok, socket}
  end

  @impl true
  def handle_event("cancel-upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :xlsx_file, ref)}
  end

  @impl true
  def handle_event("import", _params, socket) do
    insert_time_attendence_from_logs(
      socket.assigns.attendences,
      socket.assigns.current_company,
      socket.assigns.current_user
    )

    {:noreply, socket |> assign(imported: true)}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    attendences =
      fill_in_employee_info(
        parse_xlsx_to_attrs(socket.assigns.raw_attendences),
        socket.assigns.current_company,
        socket.assigns.current_user
      )

    employees = attendences |> Enum.uniq_by(fn x -> x.employee_name end)

    {:noreply,
     socket
     |> assign(
       employees: employees |> Enum.sort_by(fn x -> x.employee_name end),
       total_attendence_entries: Enum.count(attendences),
       total_employees: employees |> Enum.count(),
       attendences: attendences
     )}
  end

  @impl true
  def handle_event("validate", _params, socket) do
    {:noreply, socket}
  end

  defp insert_time_attendence_from_logs(entries, com, user) do
    case FullCircle.Authorization.can?(user, :create_time_attendence, com) do
      true ->
        Enum.each(entries, fn x ->
          if x.employee_id != "!! Not Found !!" do
            HR.insert_time_attendence_from_log(x, com)
          end
        end)

      false ->
        :not_authorise
    end
  end

  def handle_progress(:xlsx_file, entry, socket) do
    if entry.done? do
      raw_attendences =
        consume_uploaded_entry(socket, entry, fn %{path: path} ->
          {:ok, read_excel_files(path)}
        end)

      attendences =
        fill_in_employee_info(
          parse_xlsx_to_attrs(raw_attendences),
          socket.assigns.current_company,
          socket.assigns.current_user
        )

      todate = attendences |> Enum.max_by(fn x -> x.punch_time_local end)
      fromdate = attendences |> Enum.min_by(fn x -> x.punch_time_local end)
      employees = attendences |> Enum.uniq_by(fn x -> x.employee_name end)

      {:noreply,
       socket
       |> assign(
         employees: employees |> Enum.sort_by(fn x -> x.employee_name end),
         total_attendence_entries: Enum.count(attendences),
         total_employees: employees |> Enum.count(),
         from_date: fromdate.punch_time_local |> Timex.to_date(),
         to_date: todate.punch_time_local |> Timex.to_date(),
         attendences: attendences,
         raw_attendences: raw_attendences,
         filename: entry.client_name,
         imported: false
       )}
    else
      {:noreply, socket}
    end
  end

  defp error_to_string(:too_large), do: "Too large!"
  defp error_to_string(:too_many_files), do: "You have selected too many files!"
  defp error_to_string(:not_accepted), do: "You have selected an unacceptable file type"

  def read_excel_files(file) do
    blob = File.read!(file)
    {:ok, package} = XlsxReader.open(blob, source: :binary)
    {:ok, rows} = XlsxReader.sheet(package, "Att.log report")
    rows
  end

  def parse_xlsx_to_attrs(rows) do
    date_range = Enum.at(rows, 2) |> Enum.at(2) |> extract_date_range()

    rows
    |> Enum.drop(4)
    |> Enum.chunk_every(2)
    |> Enum.map(fn [info, att] ->
      Enum.map(att, fn x ->
        Regex.scan(~r/\d{2}:\d{2}/, x)
        |> List.flatten()
        |> Enum.map(fn time_str ->
          [hour, minute] = String.split(time_str, ":") |> Enum.map(&String.to_integer/1)
          Time.new!(hour, minute, 0)
        end)
      end)
      |> Enum.zip(date_range)
      |> Enum.map(fn x -> filter_times_n_split_to_map(x, info) end)
    end)
    |> List.flatten()
  end

  defp extract_date_range(date_line) do
    [start_date, end_date] =
      Regex.scan(~r/\d{4}-\d{2}-\d{2}/, date_line)
      |> List.flatten()
      |> Enum.map(&Date.from_iso8601!/1)

    Date.range(start_date, end_date) |> Enum.to_list()
  end

  defp filter_times_n_split_to_map({times, dt}, info) do
    info = Enum.reject(info, fn x -> x == "" end)

    times
    |> Enum.reduce({[], nil}, fn time, {acc, last_time} ->
      if last_time && Time.diff(time, last_time, :second) < 600 do
        {acc, last_time}
      else
        {[time | acc], time}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
    |> fill_flags_to_map
    |> Enum.map(fn x ->
      Map.merge(x, %{
        ID: Enum.at(info, 1),
        Name: Enum.at(info, 3),
        Department: Enum.at(info, 5),
        punch_card_id:
          "#{Enum.at(info, 3)}.#{Enum.at(info, 1)}.#{Enum.at(info, 5)}" |> String.replace(" ", ""),
        punch_time_local: NaiveDateTime.new!(dt, x.stamp)
      })
    end)
  end

  def fill_flags_to_map(tl) do
    Enum.map(Enum.with_index(tl, 1), fn {t, index} ->
      cond do
        index == 1 -> %{stamp: t, flag: "1_IN_1"}
        index == 2 -> %{stamp: t, flag: "1_OUT_1"}
        index == 3 -> %{stamp: t, flag: "2_IN_2"}
        index == 4 -> %{stamp: t, flag: "2_OUT_2"}
        index == 5 -> %{stamp: t, flag: "3_IN_3"}
        index == 6 -> %{stamp: t, flag: "3_OUT_3"}
        true -> %{stamp: t, flag: nil}
      end
    end)
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

        <.live_file_input upload={@uploads.xlsx_file} />
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
    <div class="w-10/12 mx-auto p-4 mb-1 border rounded-lg border-green-500 bg-green-200">
      <div class="my-2 text-center mx-auto font-bold text-2xl">
        <.link phx-click="refresh" class="button blue">Refresh</.link>
      </div>
      <%= for emps <- @employees |> Enum.chunk_every(5) do %>
        <div class="flex">
          <%= for emp <- emps do %>
            <% qry = %{
              "search[emp_name]" => emp.employee_name,
              "search[sdate]" => @from_date,
              "search[edate]" => @to_date
            } %>
            <%= if emp.employee_id == "!! Not Found !!" do %>
              <div
                :if={!@imported}
                class="w-[20%] m-1 border rounded bg-rose-200 border-rose-400 p-2 text-center"
              >
                <div class="mb-1">
                  {emp.employee_name}
                </div>
                <% clean_name =
                  Regex.run(~r/^(.+)\.\d+\..+$/, emp.employee_name)
                  |> Enum.at(1)
                  |> String.replace(~r/[^a-zA-Z0-9]/, "")
                  |> String.downcase() %>

                <a
                  id={emp.employee_name}
                  href="#"
                  phx-hook="copyAndOpen"
                  copy-text={emp.employee_name}
                  goto-url={
                    ~p"/companies/#{@current_company.id}/employees?search%5Bterms%5D=#{clean_name}"
                  }
                  class="bg-red-300 border rounded-xl border-red-600 py-1 px-2 font-bold"
                >
                  {gettext("Match Employee")}
                </a>
              </div>
            <% else %>
              <.link
                :if={@imported}
                navigate={"/companies/#{@current_company.id}/PunchIndex?#{URI.encode_query(qry)}"}
                target="_blank"
                class="w-[20%] m-1 button orange"
              >
                {emp.employee_name}
              </.link>
              <.live_component
                :if={!@imported}
                module={FullCircleWeb.PreviewAttendenceLive.Component}
                id={"id_" <> (emp.punch_card_id |> Base.encode16)}
                show_preview={false}
                raw_attendences={@raw_attendences}
                label={"Preview #{emp.employee_name}"}
              />
            <% end %>
          <% end %>
        </div>
      <% end %>
    </div>
    <div class="mt-3 text-center mx-auto font-bold text-2xl">
      <.link :if={Enum.count(@employees) > 0} phx-click="import" class="button blue">Import</.link>
    </div>
    """
  end
end
