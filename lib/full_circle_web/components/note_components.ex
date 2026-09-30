defmodule FullCircleWeb.NoteComponents do
  use Phoenix.Component
  use Gettext, backend: FullCircleWeb.Gettext

  import FullCircleWeb.CoreComponents, only: [icon: 1]

  alias FullCircle.Notes.{Attachments, Note}

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
        <%!-- Cards live in the notes panel on record pages: open the note in a
             new tab so the record stays where it was. --%>
        <a
          href={"/companies/#{@current_company.id}/notes/#{@note.id}/edit"}
          target="_blank"
          class="ml-auto text-blue-600 hover:font-bold dark:text-blue-400"
        >
          {gettext("Open")}
        </a>
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
        class="att-tile group flex items-center gap-2 rounded-lg border border-gray-200 bg-white p-2 dark:border-gray-700 dark:bg-gray-800"
      >
        <a
          href={Attachments.url(a)}
          target="_blank"
          class="flex min-w-0 flex-1 items-center gap-2"
          title={a.file_name}
        >
          <.file_thumb att={a} class="h-12 w-12 flex-none rounded" />
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

  attr :role, :string, required: true
  attr :selected, :boolean, required: true
  attr :disabled, :boolean, default: false

  @doc """
  A tappable role chip wrapping a hidden `note[visibility][]` checkbox.

  The selected look is chosen here, from `selected`, not with Tailwind's
  `has-checked:` variants: the dark theme's global remaps in app.css
  (`.dark .bg-white`, `.dark .border-gray-300`, …) are unlayered CSS and beat
  every layered utility, so a `dark:has-checked:` style never shows. The page
  re-renders on each tick (phx-change), so the server always knows.
  """
  def role_chip(assigns) do
    ~H"""
    <label
      class={[
        "role-chip cursor-pointer rounded-full border px-2 text-xs",
        if(@selected,
          do: "border-blue-600 bg-blue-600 font-semibold text-white",
          else: "border-gray-400 text-gray-700 dark:text-gray-300"
        )
      ]}
      data-selected={@selected}
    >
      <input
        type="checkbox"
        class="sr-only"
        name="note[visibility][]"
        value={@role}
        checked={@selected}
        disabled={@disabled}
      />
      {@role}
    </label>
    """
  end

  attr :att, :map, required: true
  attr :class, :any, default: nil
  attr :show_name, :boolean, default: false

  @doc """
  A file's preview, sized by `class`: the image itself for images, a type
  tile otherwise. Chooses by `Attachments.kind/1` and points at
  `Attachments.url(att, :thumb)`, so generated thumbnails and new kinds
  (video posters, audio) slot in here.
  """
  def file_thumb(assigns) do
    assigns = assign(assigns, kind: Attachments.kind(assigns.att))

    ~H"""
    <img
      :if={@kind == :image}
      src={Attachments.url(@att, :thumb)}
      alt={@att.file_name}
      loading="lazy"
      class={["object-cover", @class]}
    />
    <span
      :if={@kind != :image}
      class={[
        "relative flex flex-col items-center justify-center gap-1 overflow-hidden bg-rose-50 text-rose-700 dark:bg-rose-950 dark:text-rose-200",
        @class
      ]}
    >
      <span class="text-[10px] font-bold">{if @kind == :pdf, do: "PDF", else: gettext("FILE")}</span>
      <span :if={@show_name} class="max-w-full truncate px-2 text-xs text-gray-700 dark:text-gray-200">
        {@att.file_name}
      </span>
      <%!-- The rendered first page covers the badge; if it cannot be rendered the
           image removes itself and the badge shows through. --%>
      <img
        :if={@kind == :pdf}
        src={Attachments.url(@att, :thumb)}
        alt=""
        loading="lazy"
        onerror="this.remove()"
        class="absolute inset-0 h-full w-full bg-white object-cover object-top"
      />
      <span
        :if={@kind == :pdf and @show_name}
        class="absolute inset-x-0 bottom-0 truncate bg-black/55 px-2 py-0.5 text-xs text-white"
      >
        {@att.file_name}
      </span>
    </span>
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
          href={Attachments.url(a)}
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
          <%!-- New tab, like doc_link: record pages have no way back to the note. --%>
          <a href={t.url} target="_blank" class="hover:underline">{type_label(@type)} · {t.title}</a>
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
    # The first 4 files of any kind; PDFs are tiles in the same grid.
    shown = Enum.take(note.attachments, 4)

    assigns =
      assign(assigns,
        note: note,
        d: assigns.item.d,
        thumbs: shown,
        hidden_files: length(note.attachments) - length(shown),
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
          :if={@thumbs != []}
          class={[
            "mt-2 grid gap-0.5 overflow-hidden rounded-2xl border border-gray-200 dark:border-gray-700",
            length(@thumbs) > 1 && "grid-cols-2"
          ]}
        >
          <a
            :for={a <- @thumbs}
            href={Attachments.url(a)}
            target="_blank"
            title={a.file_name}
            class="note-thumb block"
          >
            <.file_thumb
              att={a}
              class={["w-full", if(length(@thumbs) > 1, do: "h-32", else: "h-56")]}
              show_name
            />
          </a>
        </div>
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
