defmodule FullCircleWeb.BankBatchLive.Index do
  use FullCircleWeb, :live_view

  alias FullCircle.BankPayment

  @impl true
  def mount(_params, _session, socket) do
    com = socket.assigns.current_company
    user = socket.assigns.current_user

    if FullCircle.Authorization.can?(user, :create_bank_payment_batch, com) do
      profiles = BankPayment.list_profiles(com)
      today = BankPayment.today(com)

      {:ok,
       socket
       |> assign(page_title: gettext("Bank Batches"), today: today)
       |> assign(is_admin: FullCircle.Authorization.can?(user, :admin_bank_payment_batch, com))
       |> assign(profiles: profiles, profile: List.first(profiles), payment_date: today)
       |> assign(
         selected: MapSet.new(),
         errors: [],
         duplicates: [],
         action: nil,
         open_id: nil,
         open_lines: []
       )
       |> assign(import_report: nil, show_dismissed: false)
       |> allow_upload(:result,
         accept: ~w(.txt .csv),
         max_entries: 1,
         max_file_size: 5_000_000,
         auto_upload: true,
         progress: &handle_result_progress/3
       )
       |> load_rows()
       |> load_batches()}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("You are not authorised to perform this action"))
       |> push_navigate(to: ~p"/companies/#{com.id}/dashboard")}
    end
  end

  defp load_rows(%{assigns: %{profile: nil}} = socket),
    do: assign(socket, rows: [], dismissed: [])

  defp load_rows(socket) do
    com = socket.assigns.current_company
    rows = BankPayment.eligible_payments(socket.assigns.profile, com)
    tickable = for r <- rows, r.has_bank, into: MapSet.new(), do: r.id

    # A ticked row that left the list (dismissed, batched elsewhere) is dropped.
    socket = assign(socket, selected: MapSet.intersection(socket.assigns.selected, tickable))

    assign(socket,
      rows: rows,
      dismissed: BankPayment.list_dismissed(com)
    )
  end

  defp load_batches(socket) do
    batches = BankPayment.list_batches(socket.assigns.current_company)

    socket
    |> assign(
      batches: batches,
      downloads: BankPayment.downloads_by_batch(Enum.map(batches, & &1.id))
    )
    |> refresh_open()
  end

  defp refresh_open(%{assigns: %{open_id: nil}} = socket), do: assign(socket, open_lines: [])

  defp refresh_open(socket),
    do:
      assign(socket,
        open_lines:
          BankPayment.batch_lines(socket.assigns.open_id, socket.assigns.current_company)
      )

  defp download_url(com, ids, reason \\ nil) do
    params = [ids: Enum.join(ids, ",")] ++ if(reason, do: [reason: reason], else: [])
    ~p"/companies/#{com.id}/bank_batches/download?#{params}"
  end

  # ── Selection and creation ──

  @impl true
  def handle_event("noop", _params, socket), do: {:noreply, socket}

  def handle_event("params", params, socket) do
    profile =
      Enum.find(socket.assigns.profiles, &(&1.id == params["profile_id"])) ||
        socket.assigns.profile

    date =
      case Date.from_iso8601(params["payment_date"] || "") do
        {:ok, d} -> d
        _ -> socket.assigns.payment_date
      end

    socket = assign(socket, payment_date: date, errors: [], duplicates: [])

    if profile && socket.assigns.profile && profile.id == socket.assigns.profile.id,
      do: {:noreply, socket},
      else: {:noreply, socket |> assign(profile: profile, selected: MapSet.new()) |> load_rows()}
  end

  def handle_event("toggle", %{"id" => id}, socket) do
    if Enum.any?(socket.assigns.rows, &(&1.id == id and &1.has_bank)) do
      sel = socket.assigns.selected
      sel = if MapSet.member?(sel, id), do: MapSet.delete(sel, id), else: MapSet.put(sel, id)
      {:noreply, assign(socket, selected: sel, duplicates: [])}
    else
      {:noreply, socket}
    end
  end

  def handle_event("create", _params, socket), do: create(socket, [])
  def handle_event("create_anyway", _params, socket), do: create(socket, force: true)

  def handle_event("cancel_duplicates", _params, socket),
    do: {:noreply, assign(socket, duplicates: [])}

  # ── Batch actions ──

  def handle_event("open", %{"id" => id}, socket) do
    open_id = if socket.assigns.open_id == id, do: nil, else: id
    {:noreply, socket |> assign(open_id: open_id) |> refresh_open()}
  end

  def handle_event("submit", %{"id" => id}, socket) do
    result(
      socket,
      BankPayment.mark_submitted(id, socket.assigns.current_company, socket.assigns.current_user),
      gettext("Marked submitted to bank.")
    )
  end

  def handle_event("start", %{"kind" => kind, "id" => id}, socket) do
    {:noreply, assign(socket, action: {kind, id}, errors: [])}
  end

  def handle_event("show_dismissed", _params, socket),
    do: {:noreply, update(socket, :show_dismissed, &(!&1))}

  def handle_event("undismiss", %{"id" => id}, socket) do
    result(
      socket,
      BankPayment.undismiss_payment(
        id,
        socket.assigns.current_company,
        socket.assigns.current_user
      ),
      gettext("Back on the list.")
    )
  end

  def handle_event("cancel_action", _params, socket), do: {:noreply, assign(socket, action: nil)}

  def handle_event("do_action", %{"reason" => reason}, socket) do
    %{current_company: com, current_user: user} = socket.assigns

    case socket.assigns.action do
      {"void", id} ->
        result(
          assign(socket, action: nil),
          BankPayment.void_batch(id, reason, com, user),
          gettext("Batch voided.")
        )

      {"release", id} ->
        result(
          assign(socket, action: nil),
          BankPayment.release_line(id, reason, com, user),
          gettext("Line released.")
        )

      {"return", id} ->
        result(
          assign(socket, action: nil),
          BankPayment.return_line(id, reason, com, user),
          gettext("Line marked returned.")
        )

      {"dismiss", id} ->
        result(
          assign(socket, action: nil),
          BankPayment.dismiss_payment(id, reason, com, user),
          gettext("Marked paid outside file.")
        )

      {"download", id} ->
        case BankPayment.check_download(id, reason, com, user) do
          :ok ->
            {:noreply,
             socket
             |> assign(action: nil)
             |> push_event("download", %{url: download_url(com, [id], reason)})
             |> load_batches()}

          {:error, msg} ->
            {:noreply, socket |> assign(action: nil, errors: [msg]) |> load_batches()}

          :not_authorise ->
            {:noreply,
             put_flash(socket, :error, gettext("You are not authorised to perform this action"))}
        end

      _ ->
        {:noreply, assign(socket, action: nil)}
    end
  end

  defp create(socket, opts) do
    %{
      profile: profile,
      selected: selected,
      payment_date: date,
      current_company: com,
      current_user: user
    } = socket.assigns

    case BankPayment.create_batches(
           profile && profile.id,
           MapSet.to_list(selected),
           date,
           com,
           user,
           opts
         ) do
      {:ok, batches} ->
        {:noreply,
         socket
         |> assign(selected: MapSet.new(), errors: [], duplicates: [])
         |> load_rows()
         |> load_batches()
         |> put_flash(
           :info,
           gettext("Bank file created: %{files}",
             files: Enum.map_join(batches, ", ", & &1.filename)
           )
         )
         |> push_event("download", %{url: download_url(com, Enum.map(batches, & &1.id))})}

      {:duplicates, msgs} ->
        {:noreply, assign(socket, duplicates: msgs, errors: [])}

      {:error, msgs} when is_list(msgs) ->
        {:noreply, assign(socket, errors: msgs, duplicates: [])}

      {:error, msg} ->
        {:noreply, socket |> assign(errors: [msg], duplicates: []) |> load_rows()}

      :not_authorise ->
        {:noreply,
         put_flash(socket, :error, gettext("You are not authorised to perform this action"))}
    end
  end

  defp result(socket, outcome, ok_msg) do
    case outcome do
      {:ok, _} ->
        {:noreply,
         socket |> assign(errors: []) |> load_rows() |> load_batches() |> put_flash(:info, ok_msg)}

      {:error, msg} when is_binary(msg) ->
        {:noreply, assign(socket, errors: [msg])}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, assign(socket, errors: Enum.map(cs.errors, fn {f, {m, _}} -> "#{f} #{m}" end))}

      :not_authorise ->
        {:noreply,
         put_flash(socket, :error, gettext("You are not authorised to perform this action"))}
    end
  end

  # ── Result upload ──

  defp handle_result_progress(:result, entry, socket) do
    if entry.done? do
      [text] =
        consume_uploaded_entries(socket, :result, fn %{path: path}, _entry ->
          {:ok, File.read!(path)}
        end)

      case BankPayment.import_result(
             text,
             socket.assigns.current_company,
             socket.assigns.current_user
           ) do
        {:ok, report} ->
          {:noreply,
           socket |> assign(import_report: report, errors: []) |> load_rows() |> load_batches()}

        {:error, msg} ->
          {:noreply, assign(socket, import_report: nil, errors: [msg])}

        :not_authorise ->
          {:noreply,
           put_flash(socket, :error, gettext("You are not authorised to perform this action"))}
      end
    else
      {:noreply, socket}
    end
  end

  # ── View helpers ──

  defp upload_error_text(:not_accepted), do: gettext("file type not accepted (use .txt or .csv)")
  defp upload_error_text(:too_large), do: gettext("file too large")
  defp upload_error_text(:too_many_files), do: gettext("one file at a time")
  defp upload_error_text(other), do: inspect(other)

  defp money(d), do: d |> Decimal.round(2) |> Decimal.to_string(:normal)

  defp total(rows, selected),
    do:
      rows
      |> Enum.filter(&MapSet.member?(selected, &1.id))
      |> Enum.reduce(Decimal.new(0), &Decimal.add(&1.amount, &2))

  defp stale_date?(b, today),
    do:
      b.status == "exported" and String.contains?(b.spec["filename"] || "", "{today") and
        b.header["today"] != Date.to_iso8601(today)

  defp action_prompt({"void", _}),
    do:
      gettext(
        "Void only if the bank rejected this file or it was never uploaded/approved. Voiding lets these payments go into a new file. Reason:"
      )

  defp action_prompt({"download", _}),
    do: gettext("This file may already be at the bank. Why download it again?")

  defp action_prompt({"release", _}), do: gettext("Why did the bank reject this payment?")
  defp action_prompt({"return", _}), do: gettext("Why was this paid payment returned?")
  defp action_prompt({"dismiss", _}), do: gettext("How was it paid? (cheque no, transfer ref)")
  defp action_prompt(_), do: ""

  @impl true
  def render(assigns) do
    ~H"""
    <div class="w-11/12 mx-auto">
      <p class="w-full text-3xl text-center font-medium">{@page_title}</p>

      <p :if={@profiles == []} class="text-center">
        {gettext("No bank payment profile yet. An admin sets one up under Bank Payment Setup.")}
      </p>

      <form
        :if={@profiles != []}
        id="batch-params"
        phx-change="params"
        class="flex justify-center gap-2 mb-2"
      >
        <select name="profile_id" class="border rounded px-2 py-1 dark:bg-gray-800">
          <option :for={p <- @profiles} value={p.id} selected={@profile && p.id == @profile.id}>
            {p.account_name} ({p.format_code})
          </option>
        </select>
        <input
          type="date"
          name="payment_date"
          value={Date.to_iso8601(@payment_date)}
          class="border rounded px-2 py-1 dark:bg-gray-800"
        />
      </form>

      <div
        :if={@errors != []}
        id="batch-errors"
        class="border rounded border-rose-500 bg-rose-50 dark:bg-rose-900/30 p-2 mb-2"
      >
        <p :for={e <- @errors} class="text-rose-700 dark:text-rose-300 text-sm">{e}</p>
      </div>

      <div
        :if={@action}
        class="border rounded border-amber-500 bg-amber-50 dark:bg-amber-900/30 p-2 mb-2"
      >
        <form
          id="action-form"
          phx-submit="do_action"
          class="flex flex-wrap gap-2 items-center justify-center"
        >
          <span class="text-sm">{action_prompt(@action)}</span>
          <input type="text" name="reason" class="border rounded px-2 py-1 dark:bg-gray-800 w-96" />
          <button type="submit" class="red button">{gettext("Confirm")}</button>
          <button type="button" phx-click="cancel_action" class="blue button">{gettext("Cancel")}</button>
        </form>
      </div>

      <div
        :if={@duplicates != []}
        id="duplicates"
        class="border rounded border-amber-500 bg-amber-50 dark:bg-amber-900/30 p-2 mb-2"
      >
        <p class="font-semibold">{gettext("These may already be paid:")}</p>
        <p :for={d <- @duplicates} class="text-sm">{d}</p>
        <div class="flex gap-2 justify-center mt-1">
          <button id="create-anyway" phx-click="create_anyway" class="red button">{gettext(
            "Create anyway"
          )}</button>
          <button phx-click="cancel_duplicates" class="blue button">{gettext("Cancel")}</button>
        </div>
      </div>

      <div :if={@profile} class="mb-4">
        <div class="grid grid-cols-12 bg-amber-200 dark:bg-amber-800 border-y-2 border-amber-500 font-bold p-1">
          <div class="col-span-1"></div>
          <div class="col-span-1">{gettext("Date")}</div>
          <div class="col-span-2">{gettext("Payment No")}</div>
          <div class="col-span-3">{gettext("Supplier")}</div>
          <div class="col-span-2">{gettext("Bank / Account")}</div>
          <div class="col-span-1 text-right">{gettext("Amount")}</div>
          <div class="col-span-2"></div>
        </div>
        <div
          :for={r <- @rows}
          id={"row-#{r.id}"}
          class={["grid grid-cols-12 p-1 border-b items-center", !r.has_bank && "opacity-50"]}
        >
          <div class="col-span-1 flex gap-1 items-center">
            <input
              :if={r.has_bank}
              type="checkbox"
              id={"tick-#{r.id}"}
              phx-click="toggle"
              phx-value-id={r.id}
              checked={MapSet.member?(@selected, r.id)}
            />
            <span
              :if={r.recent_change}
              class="text-xs rounded px-1 bg-amber-300 text-amber-900 dark:bg-amber-700 dark:text-amber-100"
              title={gettext("Bank details changed %{at}", at: to_string(r.changed_at))}
            >⚠</span>
          </div>
          <div class="col-span-1">{FullCircleWeb.Helpers.format_date(r.payment_date)}</div>
          <div class="col-span-2">{r.payment_no}</div>
          <div class="col-span-3 truncate">
            {r.contact_name}
            <span :if={r.last_reason} class="block text-xs text-rose-700 dark:text-rose-300">{gettext(
              "last rejected: %{r}",
              r: r.last_reason
            )}</span>
          </div>
          <div class="col-span-2 truncate">
            {if r.has_bank, do: "#{r.bank_name} #{r.account_no}", else: gettext("no bank details")}
          </div>
          <div class="col-span-1 text-right tabular-nums">{money(r.amount)}</div>
          <div class="col-span-2 text-right">
            <button
              id={"dismiss-#{r.id}"}
              phx-click="start"
              phx-value-kind="dismiss"
              phx-value-id={r.id}
              class="text-xs underline"
            >{gettext("Paid outside file")}</button>
          </div>
        </div>
        <div class="flex justify-center items-center gap-4 mt-2">
          <span>{gettext("%{n} ticked, total %{total}",
            n: MapSet.size(@selected),
            total: money(total(@rows, @selected))
          )}</span>
          <button
            id="create-file"
            phx-click="create"
            class="blue button"
            disabled={MapSet.size(@selected) == 0}
          >{gettext("Create file")}</button>
          <button id="show-dismissed" phx-click="show_dismissed" class="text-sm underline">{gettext(
            "Paid outside file (%{n})",
            n: length(@dismissed)
          )}</button>
        </div>
        <div :if={@show_dismissed} class="mt-2 border rounded p-2">
          <div :for={d <- @dismissed} class="grid grid-cols-12 text-sm border-b p-1">
            <div class="col-span-2">{d.payment_no}</div>
            <div class="col-span-4 truncate">{d.contact_name}</div>
            <div class="col-span-2 text-right tabular-nums">{money(d.amount)}</div>
            <div class="col-span-3 truncate">{d.note}</div>
            <div class="col-span-1 text-right">
              <button
                id={"undismiss-#{d.payment_id}"}
                phx-click="undismiss"
                phx-value-id={d.payment_id}
                class="underline"
              >{gettext("Undo")}</button>
            </div>
          </div>
        </div>
      </div>

      <div class="flex justify-between items-center font-bold bg-gray-200 dark:bg-gray-700 p-1">
        <span>{gettext("Batch history")}</span>
        <form
          id="result-upload-form"
          phx-change="noop"
          class="text-sm font-normal flex items-center gap-2"
        >
          <span>{gettext("Import bank result:")}</span>
          <.live_file_input upload={@uploads.result} />
          <span :for={err <- upload_errors(@uploads.result)} class="text-rose-700 dark:text-rose-300">
            {upload_error_text(err)}
          </span>
          <span
            :for={err <- Enum.flat_map(@uploads.result.entries, &upload_errors(@uploads.result, &1))}
            class="text-rose-700 dark:text-rose-300"
          >
            {upload_error_text(err)}
          </span>
        </form>
      </div>

      <div
        :if={@import_report}
        id="import-report"
        class="border rounded border-emerald-500 bg-emerald-50 dark:bg-emerald-900/30 p-2 text-sm"
      >
        <p>
          {gettext("%{file}: %{p} paid, %{r} rejected; batch %{s}",
            file: @import_report.batch.filename,
            p: length(@import_report.paid),
            r: length(@import_report.rejected),
            s: @import_report.batch.status
          )}
        </p>
        <p :for={m <- @import_report.mismatched} class="text-rose-700 dark:text-rose-300">
          {gettext("amount mismatch: %{m}", m: m)}
        </p>
        <p :for={m <- @import_report.conflicts} class="text-rose-700 dark:text-rose-300">
          {gettext("conflict: %{m}", m: m)}
        </p>
        <p :for={m <- @import_report.unmatched} class="text-rose-700 dark:text-rose-300">
          {gettext("unknown record: %{m}", m: m)}
        </p>
        <p :if={@import_report.missing != []}>
          {gettext("not in the result yet: %{m}", m: Enum.join(@import_report.missing, ", "))}
        </p>
      </div>

      <div :for={b <- @batches} id={"batch-#{b.id}"} class="border-b p-1">
        <div class="grid grid-cols-12 items-center text-sm">
          <div class="col-span-1">
            {FullCircleWeb.Helpers.format_date(DateTime.to_date(b.inserted_at))}
          </div>
          <div class="col-span-3">
            <button
              id={"open-#{b.id}"}
              phx-click="open"
              phx-value-id={b.id}
              class="text-blue-600 dark:text-blue-400 underline"
            >{b.filename}</button>
            <span
              :if={stale_date?(b, @today)}
              class="block text-xs text-amber-700 dark:text-amber-300"
            >
              {gettext(
                "created on %{d}; RHB expects today's date — void and create a new file if RHB refuses it",
                d: b.header["today"]
              )}
            </span>
          </div>
          <div class="col-span-1">{FullCircleWeb.Helpers.format_date(b.payment_date)}</div>
          <div class="col-span-1 text-right">{b.count}</div>
          <div class="col-span-1 text-right tabular-nums">{money(b.total)}</div>
          <div class="col-span-1">{b.status}</div>
          <div class="col-span-2 text-xs">
            {b.created_by && b.created_by.email}
            <span :if={dl = List.first(@downloads[b.id] || [])} class="block">
              {gettext("first download %{at}, %{n}×",
                at: Calendar.strftime(dl.inserted_at, "%d/%m %H:%M"),
                n: length(@downloads[b.id])
              )}
            </span>
          </div>
          <div class="col-span-2 flex flex-wrap gap-1 justify-end">
            <a
              :if={b.status != "voided" and (@downloads[b.id] || []) == []}
              id={"download-#{b.id}"}
              href={download_url(@current_company, [b.id])}
              class="blue button"
            >{gettext("Download")}</a>
            <button
              :if={
                b.status != "voided" and (@downloads[b.id] || []) != [] and
                  (b.status == "exported" or @is_admin)
              }
              id={"download-again-#{b.id}"}
              phx-click="start"
              phx-value-kind="download"
              phx-value-id={b.id}
              class="blue button"
            >{gettext("Download again")}</button>
            <button
              :if={b.status == "exported"}
              id={"submit-#{b.id}"}
              phx-click="submit"
              phx-value-id={b.id}
              class="blue button"
            >{gettext("Mark submitted")}</button>
            <button
              :if={b.status == "exported" or (b.status == "submitted" and @is_admin)}
              id={"void-#{b.id}"}
              phx-click="start"
              phx-value-kind="void"
              phx-value-id={b.id}
              class="red button"
            >{gettext("Void")}</button>
          </div>
        </div>
        <div :if={@open_id == b.id} class="ml-8 mt-1 text-sm">
          <div :for={l <- @open_lines} class="grid grid-cols-12 border-b p-1">
            <div class="col-span-2">{l.payment_no}</div>
            <div class="col-span-3 truncate">{l.contact_name}</div>
            <div class="col-span-2 text-right tabular-nums">{money(l.amount)}</div>
            <div class="col-span-1">{l.status}</div>
            <div class="col-span-3 truncate">{l.bank_reason}</div>
            <div class="col-span-1 text-right">
              <button
                :if={l.status == "pending" and b.status in ["submitted", "partly_rejected"]}
                id={"release-#{l.id}"}
                phx-click="start"
                phx-value-kind="release"
                phx-value-id={l.id}
                class="underline"
              >{gettext("Rejected")}</button>
              <button
                :if={l.status == "paid" and @is_admin}
                id={"return-#{l.id}"}
                phx-click="start"
                phx-value-kind="return"
                phx-value-id={l.id}
                class="underline"
              >{gettext("Returned")}</button>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
