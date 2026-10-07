defmodule FullCircleWeb.ReceiptCapture do
  @moduledoc """
  Receipt capture on New Payment / New Purchase Invoice. The form owns a note
  tray filled from the phone (📱) or desktop (📎); the first file is read by
  `Receipts.Extract` and seeds the form's *empty* fields through
  `Receipts.Prefill`; Save attaches the tray as a 🧾 Receipt note on the new
  document inside the same transaction. Contract:
  `.claude/skills/receipt-capture.md`.
  """
  use FullCircleWeb, :html

  import Phoenix.LiveView, only: [start_async: 3]

  alias Ecto.Multi
  alias FullCircle.{Notes, Receipts, Sys}
  alias FullCircle.Notes.{Attachments, Trays}
  alias FullCircle.BankReconciliation.LlmClient

  # Fields filled together or not at all: half a contact (a name the clerk
  # typed with the receipt's id) would save the wrong party.
  @groups [
    ~w(contact_name contact_id tax_id reg_no),
    ~w(funds_account_name funds_account_id)
  ]

  @doc """
  `seed_attrs` laid under `current` form params: a field is filled only when
  blank there (nil, "", or a zero amount), a group only when its first field
  is blank, and lines only when no current line has a good, quantity or price.
  """
  def merge_params(current, seed_attrs, detail_key) do
    seed = Map.new(seed_attrs, fn {k, v} -> {to_string(k), v} end)
    lines_key = to_string(detail_key)
    grouped = List.flatten(@groups)

    merged =
      Enum.reduce(@groups, current, fn [lead | _] = group, acc ->
        if blank?(acc[lead]) and Map.has_key?(seed, lead),
          do: Map.merge(acc, Map.take(seed, group)),
          else: acc
      end)

    merged =
      seed
      |> Map.drop([lines_key | grouped])
      |> Enum.reduce(merged, fn {k, v}, acc ->
        if blank?(acc[k]), do: Map.put(acc, k, v), else: acc
      end)

    if lines_blank?(current[lines_key]) and is_list(seed[lines_key]) do
      lines =
        seed[lines_key]
        |> Enum.with_index()
        |> Map.new(fn {line, i} -> {to_string(i), line} end)

      Map.put(merged, lines_key, lines)
    else
      merged
    end
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(%Decimal{} = d), do: Decimal.eq?(d, 0)

  defp blank?(s) when is_binary(s) do
    case Decimal.parse(String.trim(s)) do
      {d, ""} -> Decimal.eq?(d, 0)
      _ -> false
    end
  end

  defp blank?(_), do: false

  defp lines_blank?(nil), do: true
  defp lines_blank?(lines) when is_map(lines), do: lines_blank?(Map.values(lines))

  defp lines_blank?(lines) when is_list(lines) do
    Enum.all?(lines, fn line ->
      blank?(line["good_name"]) and blank?(line["quantity"]) and blank?(line["unit_price"])
    end)
  end

  @doc "Appends the 🧾 Receipt note step when the tray has files and the user may write notes."
  def attach_multi(tray_id, doc_type, doc_key, com, user) do
    if Trays.has_files?(tray_id, com, user) and can_note?(com, user) do
      fn multi ->
        Multi.run(multi, :receipt_note, fn _repo, changes ->
          doc = Map.fetch!(changes, doc_key)

          %{
            "subject_type" => doc_type,
            "subject_id" => doc.id,
            "title" => "🧾 " <> gettext("Receipt"),
            "tray_id" => tray_id
          }
          |> Notes.create_note(com, user)
          |> case do
            {:ok, note} -> {:ok, note}
            :not_authorise -> {:error, :not_authorise}
            {:error, reason} -> {:error, reason}
          end
        end)
      end
    else
      &Function.identity/1
    end
  end

  @doc "True when the tray holds files that this user cannot attach as a note."
  def attach_blocked?(tray_id, com, user),
    do: Trays.has_files?(tray_id, com, user) and not can_note?(com, user)

  defp can_note?(com, user), do: FullCircle.Authorization.can?(user, :create_note, com)

  def init(socket) do
    tray_id = Ecto.UUID.generate()

    if Phoenix.LiveView.connected?(socket),
      do: FullCircleWeb.NoteFiles.listen_self({:tray, tray_id})

    assign(socket,
      receipt_tray_id: tray_id,
      receipt_files: [],
      receipt_state: :idle,
      receipt: nil,
      receipt_usage: nil,
      receipt_error: nil,
      receipt_contact_ids: nil,
      receipt_settings: Sys.llm_settings(socket.assigns.current_company, :receipt)
    )
  end

  @doc "A file landed or left: reload the tray; the first file is read once."
  def files_changed(socket, detail_key) do
    %{receipt_tray_id: id, current_company: com, current_user: user} = socket.assigns
    socket = assign(socket, receipt_files: Trays.list(id, com, user))

    case {socket.assigns.receipt_state, socket.assigns.receipt_files} do
      {:idle, [_ | _]} -> read(socket, nil, detail_key)
      _ -> socket
    end
  end

  def discard_file(socket, att_id, detail_key) do
    %{receipt_tray_id: id, current_company: com, current_user: user} = socket.assigns
    Trays.discard_file(att_id, id, com, user)
    files_changed(socket, detail_key)
  end

  @doc "Read one tray file (nil: the first) in the background."
  def read(socket, att_id, detail_key) do
    %{receipt_files: files, receipt_settings: settings, current_company: com, current_user: user} =
      socket.assigns

    att = Enum.find(files, &(&1.id == att_id)) || List.first(files)

    cond do
      is_nil(att) ->
        socket

      settings["llm-provider"] in [nil, "", "none"] ->
        assign(socket, receipt_state: :off)

      true ->
        path = Attachments.abs_path(att)
        content_type = att.content_type

        socket
        |> assign(receipt_state: :reading, receipt_error: nil)
        |> start_async(:receipt, fn ->
          with {:ok, extracted, usage} <- Receipts.Extract.run(path, content_type, settings) do
            {:ok, Receipts.Prefill.build(extracted, com, user, detail_key), extracted, usage}
          end
        end)
    end
  end

  @doc "The read came back: `{socket, seed}` to merge, or `{socket, nil}`."
  def finished(socket, {:ok, {:ok, seed, extracted, usage}}) do
    {assign(socket,
       receipt_state: :done,
       receipt: %{
         extracted: extracted,
         warnings: seed.warnings,
         total: seed.total,
         duplicate: nil
       },
       receipt_usage: LlmClient.format_usage(usage),
       receipt_contact_ids: seed.contact_ids
     ), seed}
  end

  def finished(socket, {:ok, {:error, reason}}),
    do: {assign(socket, receipt_state: :error, receipt_error: to_string(reason)), nil}

  def finished(socket, {:exit, reason}),
    do: {assign(socket, receipt_state: :error, receipt_error: inspect(reason)), nil}

  @doc """
  The clerk changed the form: re-check the duplicate warning against the
  current contact. The original warnings from the read stay; the duplicate
  line is replaced.
  """
  def recheck_duplicate(%{assigns: %{receipt: %{} = receipt}} = socket, params, detail_key) do
    com = socket.assigns.current_company

    warnings =
      Enum.reject(receipt.warnings, &String.starts_with?(&1, gettext("Possible duplicate")))

    dup = Receipts.Prefill.duplicate_warning(params, detail_key, com)
    assign(socket, receipt: %{receipt | warnings: warnings, duplicate: dup})
  end

  def recheck_duplicate(socket, _params, _detail_key), do: socket

  attr :id, :string, required: true
  attr :tray_id, :string, required: true
  attr :files, :list, required: true
  attr :state, :atom, required: true
  attr :receipt, :map, default: nil
  attr :usage, :string, default: nil
  attr :error, :string, default: nil
  attr :keyed_total, :any, default: nil
  attr :label, :string, required: true
  attr :current_company, :map, required: true
  attr :current_user, :map, required: true

  def receipt_capture(assigns) do
    assigns =
      assign(assigns, photo: Attachments.photo_settings(assigns.current_company))

    ~H"""
    <div
      id={"#{@id}-box"}
      data-tray-id={@tray_id}
      phx-hook="NoteDrop"
      data-url={~p"/companies/#{@current_company.id}/note_trays/#{@tray_id}/files"}
      data-max-bytes={Attachments.max_bytes()}
      data-max-edge={@photo.max_edge}
      data-quality={@photo.quality}
      class="@container mb-2 rounded-lg border border-sky-400 bg-sky-50 p-2 text-sm text-gray-900 dark:border-sky-700 dark:bg-sky-950 dark:text-gray-100"
    >
      <div class="flex flex-wrap items-center gap-2">
        <span class="font-semibold">🧾 {gettext("Receipt")}</span>
        <FullCircleWeb.NoteComponents.attach_button
          id={"#{@id}-attach"}
          url={~p"/companies/#{@current_company.id}/note_trays/#{@tray_id}/files"}
          company={@current_company}
        />
        <.live_component
          module={FullCircleWeb.NoteLive.PhoneQrComponent}
          id={"#{@id}-phone"}
          target={{:tray, @tray_id}}
          label={@label}
          current_company={@current_company}
          current_user={@current_user}
        />
        <span id={"#{@id}-status"} class="text-gray-700 dark:text-gray-300">
          <%= case @state do %>
            <% :idle -> %>
              {gettext("Snap or drop a bill / receipt — the AI fills the empty fields.")}
            <% :reading -> %>
              ⏳ {gettext("Reading receipt…")}
            <% :done -> %>
              ✓ {gettext("Read.")}
              <span class="text-xs text-gray-500 dark:text-gray-400">{@usage}</span>
            <% :error -> %>
              <span class="text-rose-700 dark:text-rose-300">
                {gettext("Couldn't read receipt:")} {@error}
              </span>
            <% :off -> %>
              {gettext("AI reading off — set it under Company → AI for receipts / bills.")}
          <% end %>
        </span>
        <button
          :if={@state in [:done, :error] and @files != []}
          type="button"
          id={"#{@id}-read-again"}
          phx-click="receipt_read_again"
          class="whitespace-nowrap rounded-full border border-gray-300 px-3 py-0.5 hover:bg-gray-100 dark:border-gray-600 dark:hover:bg-gray-800"
        >
          ↻ {gettext("Read again")}
        </button>
      </div>
      <FullCircleWeb.NoteComponents.file_grid
        id={"#{@id}-files"}
        attachments={@files}
        removable
        remove_event="receipt_discard_file"
        confirm={nil}
      />
      <div :if={@receipt} id={"#{@id}-read"} class="mt-2 grid gap-1">
        <% ex = @receipt.extracted %>
        <p :if={ex.recognized}>
          <span class="font-medium">{ex.supplier_name || gettext("(no supplier name)")}</span>
          <span :if={ex.supplier_tin}> · TIN {ex.supplier_tin}</span>
          <span :if={ex.supplier_brn}> · BRN {ex.supplier_brn}</span>
          <span :if={ex.doc_no}> · #{ex.doc_no}</span>
          <span :if={ex.date}> · {ex.date}</span>
          <span :if={ex.total}> · {gettext("Total")} {ex.total}</span>
        </p>
        <p :if={!ex.recognized} class="italic">{ex.summary}</p>
        <p :if={@receipt.total && @keyed_total} id={"#{@id}-totals"}>
          <% diff = FullCircle.EInvMetas.Prefill.variance(@keyed_total, @receipt.total) %>
          <span class={
            if diff,
              do: "text-rose-700 dark:text-rose-300",
              else: "text-emerald-700 dark:text-emerald-300"
          }>
            {gettext("Keyed RM %{k} · Receipt RM %{r}",
              k: Decimal.round(@keyed_total, 2),
              r: @receipt.total
            )}
            {if diff, do: gettext("(differs by %{d})", d: Decimal.round(diff, 2)), else: "✓"}
          </span>
        </p>
        <ul class="list-disc pl-5 text-amber-800 dark:text-amber-300">
          <li :for={w <- @receipt.warnings ++ List.wrap(@receipt.duplicate)}>{w}</li>
        </ul>
      </div>
    </div>
    """
  end
end
