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

  # --- feed ----------------------------------------------------------------

  @avatar_colors ~w(bg-indigo-500 bg-teal-600 bg-amber-600 bg-rose-500 bg-sky-600 bg-emerald-600 bg-violet-500 bg-orange-500)

  attr :email, :string, required: true

  def avatar(assigns) do
    local = assigns.email |> to_string() |> String.split("@") |> hd()

    assigns =
      assign(assigns,
        initials:
          local |> String.replace(~r/[^A-Za-z0-9]/, "") |> String.slice(0, 2) |> String.upcase(),
        color: Enum.at(@avatar_colors, :erlang.phash2(assigns.email, length(@avatar_colors)))
      )

    ~H"""
    <div class={[
      "flex h-10 w-10 flex-none items-center justify-center rounded-full text-sm font-bold text-white",
      @color
    ]}>
      {@initials}
    </div>
    """
  end

  @doc "X-style relative time: now, 5m, 3h, then a date in the company's timezone."
  def ago(%DateTime{} = dt, company) do
    secs = DateTime.diff(DateTime.utc_now(), dt)

    cond do
      secs < 60 -> gettext("now")
      secs < 3600 -> "#{div(secs, 60)}m"
      secs < 86_400 -> "#{div(secs, 3600)}h"
      true -> local_date(dt, company)
    end
  end

  defp local_date(dt, company) do
    local = Timex.to_datetime(dt, company.timezone)

    if local.year == Timex.to_datetime(DateTime.utc_now(), company.timezone).year,
      do: Calendar.strftime(local, "%b %-d"),
      else: Calendar.strftime(local, "%-d %b %Y")
  end

  attr :target, :any, required: true
  attr :type, :string, required: true
  attr :kind, :atom, default: :link, values: [:subject, :link]

  @doc "An amber (subject) or sky-blue (link) chip naming a linked record."
  def record_chip(assigns) do
    ~H"""
    <span class={[
      "inline-block max-w-full truncate rounded-full border px-2 align-middle text-xs",
      @kind == :subject &&
        "border-amber-400 bg-amber-100 text-amber-900 dark:border-amber-600 dark:bg-amber-900 dark:text-amber-100",
      @kind == :link &&
        "border-sky-400 bg-sky-100 text-sky-900 dark:border-sky-600 dark:bg-sky-900 dark:text-sky-100"
    ]}>
      <%= case @target do %>
        <% {:ok, %{url: nil} = t} -> %>
          {type_label(@type)} · {t.title}
        <% {:ok, t} -> %>
          <.link navigate={t.url} class="hover:underline">{type_label(@type)} · {t.title}</.link>
        <% {:error, :restricted} -> %>
          {gettext("Restricted record")}
        <% _ -> %>
          ({gettext("deleted")} {type_label(@type)})
      <% end %>
    </span>
    """
  end

  attr :id, :string, required: true
  attr :item, :map, required: true, doc: "%{note: Note, d: Notes.feed_details/3 entry}"
  attr :current_company, :map, required: true

  @doc "One note as a feed post."
  def note_post(assigns) do
    note = assigns.item.note

    {images, others} =
      Enum.split_with(note.attachments, &String.starts_with?(&1.content_type, "image/"))

    shown_images = Enum.take(images, 4)
    first_other = List.first(others)
    hidden = length(note.attachments) - length(shown_images) - if(first_other, do: 1, else: 0)

    assigns =
      assign(assigns,
        note: note,
        d: assigns.item.d,
        images: shown_images,
        first_other: first_other,
        hidden_files: hidden,
        path: "/companies/#{assigns.current_company.id}/notes/#{note.id}/edit"
      )

    ~H"""
    <article
      id={@id}
      class="flex gap-3 border-b border-gray-200 px-4 py-3 hover:bg-gray-50 dark:border-gray-700 dark:hover:bg-gray-800/60"
    >
      <.avatar email={@note.author.email} />
      <div class="min-w-0 flex-1">
        <div class="flex flex-wrap items-center gap-x-1 text-sm">
          <span class="font-bold">{@note.author.email |> String.split("@") |> hd()}</span>
          <span
            class="text-gray-500 dark:text-gray-400"
            title={FullCircleWeb.Helpers.format_datetime(@note.inserted_at, @current_company)}
          >
            · {ago(@note.inserted_at, @current_company)}
          </span>
          <span
            :if={@note.visibility}
            class="ml-1 rounded-full border border-rose-300 bg-rose-100 px-2 text-xs text-rose-800 dark:border-rose-700 dark:bg-rose-900 dark:text-rose-100"
          >
            🔒 {Enum.join(@note.visibility, ", ")}
          </span>
        </div>

        <div :if={@d.subject || @d.links != []} class="mt-0.5 flex flex-wrap gap-1">
          <.record_chip
            :if={@d.subject}
            target={@d.subject}
            type={@note.subject_type}
            kind={:subject}
          />
          <.record_chip :for={l <- @d.links} target={l.target} type={l.type} />
        </div>

        <.link navigate={@path} class="mt-1 block">
          <div :if={@note.title} class="note-title font-bold">{@note.title}</div>
          <div phx-no-format class="line-clamp-8 whitespace-pre-wrap break-words">{@note.body}</div>
        </.link>

        <div
          :if={@images != []}
          class={[
            "mt-2 grid gap-0.5 overflow-hidden rounded-2xl border border-gray-200 dark:border-gray-700",
            length(@images) > 1 && "grid-cols-2"
          ]}
        >
          <a
            :for={a <- @images}
            href={"/companies/#{@current_company.id}/note_attachments/#{a.id}"}
            target="_blank"
          >
            <img
              src={"/companies/#{@current_company.id}/note_attachments/#{a.id}"}
              alt={a.file_name}
              loading="lazy"
              class={["w-full object-cover", if(length(@images) > 1, do: "h-32", else: "max-h-72")]}
            />
          </a>
        </div>

        <a
          :if={@first_other}
          href={"/companies/#{@current_company.id}/note_attachments/#{@first_other.id}"}
          target="_blank"
          class="mt-2 flex items-center gap-2 rounded-xl border border-gray-200 p-2 hover:bg-gray-50 dark:border-gray-700 dark:hover:bg-gray-800"
        >
          <span class="flex h-9 w-8 flex-none items-center justify-center rounded bg-rose-100 text-[9px] font-bold text-rose-700 dark:bg-rose-900 dark:text-rose-200">
            PDF
          </span>
          <span class="min-w-0 truncate text-sm">{@first_other.file_name}</span>
        </a>
        <div :if={@hidden_files > 0} class="mt-1 text-xs text-gray-500">
          + {ngettext("1 more file", "%{count} more files", @hidden_files)}
        </div>

        <.link navigate={@path} class="mt-2 flex gap-8 text-sm text-gray-500 dark:text-gray-400">
          <span title={gettext("Notes about this note")}>💬
          <span class="note-replies">{@d.replies}</span></span>
          <span title={gettext("Links")}>🔗 <span class="note-links">{length(@d.links)}</span></span>
          <span title={gettext("Files")}>📎 <span class="note-files">{length(@note.attachments)}</span></span>
        </.link>
      </div>
    </article>
    """
  end
end
