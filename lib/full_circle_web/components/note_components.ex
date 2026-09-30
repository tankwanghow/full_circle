defmodule FullCircleWeb.NoteComponents do
  use Phoenix.Component
  use Gettext, backend: FullCircleWeb.Gettext

  import FullCircleWeb.CoreComponents, only: [icon: 1]

  alias FullCircle.Notes.Note

  def type_label("Employee"), do: gettext("Employee")
  def type_label("Contact"), do: gettext("Contact")
  def type_label("Good"), do: gettext("Good")
  def type_label("Note"), do: gettext("Note")
  def type_label("Invoice"), do: gettext("Invoice")
  def type_label("PurInvoice"), do: gettext("Purchase Invoice")
  def type_label("Receipt"), do: gettext("Receipt")
  def type_label("Payment"), do: gettext("Payment")
  def type_label("CreditNote"), do: gettext("Credit Note")
  def type_label("DebitNote"), do: gettext("Debit Note")
  def type_label("Journal"), do: gettext("Journal")
  def type_label("Deposit"), do: gettext("Deposit")
  def type_label("ReturnCheque"), do: gettext("Return Cheque")
  def type_label(other), do: other

  attr :visibility, :any, required: true

  def visibility_badge(%{visibility: nil} = assigns) do
    ~H"""
    <span class="rounded px-1 text-xs bg-green-100 text-green-800 dark:bg-green-900 dark:text-green-200">
      {gettext("Everyone")}
    </span>
    """
  end

  def visibility_badge(assigns) do
    ~H"""
    <span class="rounded px-1 text-xs bg-rose-100 text-rose-800 dark:bg-rose-900 dark:text-rose-200">
      🔒 {Enum.join(@visibility, ", ")}
    </span>
    """
  end

  attr :target, :any, required: true
  attr :type, :string, required: true

  def record_link(%{target: {:ok, t}} = assigns) do
    assigns = assign(assigns, :t, t)

    ~H"""
    <.link navigate={@t.url} class="text-blue-600 hover:font-bold dark:text-blue-400">
      {type_label(@type)}: {@t.title}
    </.link>
    """
  end

  def record_link(%{target: {:error, :restricted}} = assigns) do
    ~H"""
    <span class="italic text-gray-500">{gettext("Restricted record")}</span>
    """
  end

  def record_link(assigns) do
    ~H"""
    <span class="italic text-gray-500">({gettext("deleted")} {type_label(@type)})</span>
    """
  end

  attr :note, Note, required: true
  attr :relation, :atom, default: nil
  attr :current_company, :map, required: true
  attr :can_edit, :boolean, default: false
  attr :target, :any, default: nil

  def note_card(assigns) do
    ~H"""
    <div
      id={"note-card-#{@note.id}"}
      class="my-1 rounded border border-gray-300 bg-white p-2 text-left dark:border-gray-600 dark:bg-gray-800"
    >
      <div class="flex flex-wrap items-center gap-1 text-xs text-gray-500 dark:text-gray-400">
        <.visibility_badge visibility={@note.visibility} />
        <span :if={@relation == :linked} class="rounded border px-1">↩ {gettext("linked")}</span>
        <span>{@note.author && @note.author.email}</span>
        <span>· {FullCircleWeb.Helpers.format_datetime(@note.inserted_at, @current_company)}</span>
        <.link
          navigate={"/companies/#{@current_company.id}/notes/#{@note.id}/edit"}
          class="ml-auto text-blue-600 hover:font-bold dark:text-blue-400"
        >
          {gettext("Open")}
        </.link>
      </div>
      <div :if={@note.title} class="font-semibold">{@note.title}</div>
      <div class="whitespace-pre-wrap">{@note.body}</div>
      <.attachment_list
        attachments={@note.attachments}
        current_company={@current_company}
        can_edit={@can_edit}
        target={@target}
      />
      <.attach_button :if={@can_edit} note_id={@note.id} current_company={@current_company} />
    </div>
    """
  end

  attr :attachments, :list, required: true
  attr :current_company, :map, required: true
  attr :can_edit, :boolean, default: false
  attr :target, :any, default: nil

  @doc "Files as a tidy grid of tiles: a thumbnail for images, a type badge otherwise."
  def attachment_tiles(assigns) do
    ~H"""
    <div :if={@attachments != []} class="grid grid-cols-1 gap-2 sm:grid-cols-2">
      <div
        :for={a <- @attachments}
        id={"att-#{a.id}"}
        class="group flex items-center gap-2 rounded-lg border border-gray-200 bg-white p-2 dark:border-gray-700 dark:bg-gray-800"
      >
        <a
          href={"/companies/#{@current_company.id}/note_attachments/#{a.id}"}
          target="_blank"
          class="flex min-w-0 flex-1 items-center gap-2"
          title={a.file_name}
        >
          <img
            :if={String.starts_with?(a.content_type, "image/")}
            src={"/companies/#{@current_company.id}/note_attachments/#{a.id}"}
            alt=""
            loading="lazy"
            class="h-10 w-10 flex-none rounded object-cover"
          />
          <span
            :if={!String.starts_with?(a.content_type, "image/")}
            class="flex h-10 w-10 flex-none items-center justify-center rounded bg-rose-100 text-[10px] font-bold text-rose-700 dark:bg-rose-900 dark:text-rose-200"
          >
            PDF
          </span>
          <span class="min-w-0">
            <span class="block truncate text-sm text-gray-800 dark:text-gray-100">{a.file_name}</span>
            <span class="block text-xs text-gray-500 dark:text-gray-400">{file_size(a.byte_size)}</span>
          </span>
        </a>
        <button
          :if={@can_edit}
          type="button"
          phx-click="remove_attachment"
          phx-value-id={a.id}
          phx-target={@target}
          data-confirm={gettext("Remove this file from the note?")}
          class="flex-none rounded p-1 text-gray-400 hover:bg-rose-50 hover:text-rose-600 dark:hover:bg-rose-950"
          title={gettext("Remove")}
        >
          <.icon name="hero-x-mark" class="h-4 w-4" />
        </button>
      </div>
    </div>
    """
  end

  defp file_size(nil), do: ""
  defp file_size(b) when b < 1_000, do: "#{b} B"
  defp file_size(b) when b < 1_000_000, do: "#{round(b / 1_000)} KB"
  defp file_size(b), do: "#{Float.round(b / 1_000_000, 1)} MB"

  attr :attachments, :list, required: true
  attr :current_company, :map, required: true
  attr :can_edit, :boolean, default: false
  attr :target, :any, default: nil

  def attachment_list(assigns) do
    ~H"""
    <div :if={@attachments != []} class="mt-1 flex flex-wrap gap-2 text-sm">
      <span :for={a <- @attachments} id={"att-#{a.id}"} class="flex items-center gap-1">
        <a
          href={"/companies/#{@current_company.id}/note_attachments/#{a.id}"}
          target="_blank"
          class="text-blue-600 hover:font-bold dark:text-blue-400"
        >
          📎 {a.file_name}
        </a>
        <button
          :if={@can_edit}
          type="button"
          phx-click="remove_attachment"
          phx-value-id={a.id}
          phx-target={@target}
          data-confirm={gettext("Remove this file from the note?")}
          class="text-rose-600 dark:text-rose-400"
          title={gettext("Remove")}
        >
          <.icon name="hero-x-mark" class="h-4 w-4" />
        </button>
      </span>
    </div>
    """
  end

  attr :note_id, :string, required: true
  attr :current_company, :map, required: true

  def attach_button(assigns) do
    ~H"""
    <span class="inline-flex items-center gap-2 text-sm">
      <button
        type="button"
        id={"attach-#{@note_id}"}
        phx-hook="NoteAttach"
        data-url={"/companies/#{@current_company.id}/notes/#{@note_id}/attachments"}
        data-max-bytes={FullCircle.Notes.Attachments.max_bytes()}
        class="rounded border border-gray-400 px-2 hover:bg-gray-100 dark:border-gray-500 dark:hover:bg-gray-700"
      >
        📎 {gettext("Attach file")}
      </button>
      <span id={"attach-#{@note_id}-msg"} phx-update="ignore" class="text-rose-600 dark:text-rose-400"></span>
    </span>
    """
  end

  attr :count, :integer, required: true
  attr :id, :string, required: true

  def notes_count_badge(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="open_notes"
      phx-value-id={@id}
      class={[
        "rounded px-1 text-xs",
        @count > 0 && "bg-blue-600 text-white dark:bg-blue-500",
        @count == 0 && "text-gray-400 dark:text-gray-500"
      ]}
      title={gettext("Notes")}
    >
      📝 {if @count > 0, do: @count, else: "—"}
    </button>
    """
  end
end
