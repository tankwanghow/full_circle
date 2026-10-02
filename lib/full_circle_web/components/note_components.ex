defmodule FullCircleWeb.NoteComponents do
  use Phoenix.Component
  use Gettext, backend: FullCircleWeb.Gettext

  import FullCircleWeb.CoreComponents, only: [icon: 1]

  alias FullCircle.Notes.{Attachments, Note}

  def type_label("Employee"), do: gettext("Employee")
  def type_label("Contact"), do: gettext("Contact")
  def type_label("Good"), do: gettext("Good")
  def type_label("Account"), do: gettext("Account")
  def type_label("FixedAsset"), do: gettext("Fixed Asset")
  def type_label("Note"), do: gettext("Note")
  def type_label("Task"), do: gettext("Task")
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

  attr :visibility, :any, required: true, doc: "the form's current visibility (list or nil)"
  attr :id_prefix, :string, required: true
  attr :disabled, :boolean, default: false
  attr :target, :any, default: nil
  attr :field_name, :string, default: "note[visibility][]"
  attr :private_title, :any, default: nil

  attr :roles, :boolean,
    default: true,
    doc: "false shows only Everyone and Private (a task's notes: the task rule overrides roles)"

  @doc """
  Everyone · 🔒 Private · manager · supervisor · cashier · clerk · auditor.

  Admin is not a chip (admins read every note) and neither is guest (guests
  cannot open notes). Private is stored as `["admin"]`: readable by admins
  and the writer only. The host handles `visibility_everyone` and
  `visibility_private` clicks; ticking a role while Private is on replaces
  it (see `Notes` normalize). Selected looks are chosen here, not with
  `has-checked:` — see `role_chip/1`.
  """
  def visibility_chips(assigns) do
    roles = assigns.visibility || []
    private = roles == Note.private_visibility()

    assigns =
      assign(assigns,
        selected_roles: roles,
        show_roles: assigns.roles,
        private: private,
        everyone: roles == []
      )

    ~H"""
    <button
      type="button"
      id={"#{@id_prefix}-everyone"}
      phx-click="visibility_everyone"
      phx-target={@target}
      disabled={@disabled}
      data-selected={@everyone}
      class={[
        "rounded-full border px-2 text-xs",
        if(@everyone,
          do: "border-green-600 bg-green-600 font-semibold text-white",
          else: "border-gray-400 text-gray-700 dark:text-gray-300"
        )
      ]}
    >
      {gettext("Everyone")}
    </button>
    <button
      type="button"
      id={"#{@id_prefix}-private"}
      phx-click="visibility_private"
      phx-target={@target}
      disabled={@disabled}
      data-selected={@private}
      title={@private_title || gettext("Only admins and the writer can read it.")}
      class={[
        "rounded-full border px-2 text-xs",
        if(@private,
          do: "border-rose-600 bg-rose-600 font-semibold text-white",
          else: "border-gray-400 text-gray-700 dark:text-gray-300"
        )
      ]}
    >
      🔒 {gettext("Private")}
    </button>
    <input type="hidden" name={@field_name} value="" />
    <input :if={@private} type="hidden" name={@field_name} value="admin" />
    <.role_chip
      :for={role <- if(@show_roles, do: Note.choosable_roles(), else: [])}
      role={role}
      selected={role in @selected_roles}
      disabled={@disabled}
      field_name={@field_name}
    />
    """
  end

  attr :role, :string, required: true
  attr :selected, :boolean, required: true
  attr :disabled, :boolean, default: false
  attr :field_name, :string, default: "note[visibility][]"

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
        name={@field_name}
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

  attr :target, :any,
    required: true,
    doc: "{:ok, %{title, url}} | {:error, :restricted | :not_found}"

  attr :type, :string, required: true
  attr :kind, :atom, default: :link, values: [:subject, :link]
  slot :inner_block, doc: "trailing controls (e.g. a ✕ remove button); never truncated"

  @doc """
  An amber (subject) or sky-blue (link) chip naming a linked record — the one
  chip used by the feed, the note page and the task page. Capped at 20rem: the
  "Type · title" text is cut with an ellipsis and shown in full on hover; the
  inner block (✕) sits outside the cut text so it always shows.
  """
  def record_chip(assigns) do
    assigns = assign(assigns, :text, chip_text(assigns.type, assigns.target))

    ~H"""
    <span
      title={@text}
      class={[
        "inline-flex max-w-xs items-center gap-1 rounded-full border px-2 align-middle text-xs",
        @kind == :subject &&
          "border-amber-400 bg-amber-100 text-amber-900 dark:border-amber-600 dark:bg-amber-900 dark:text-amber-100",
        @kind == :link &&
          "border-sky-400 bg-sky-100 text-sky-900 dark:border-sky-600 dark:bg-sky-900 dark:text-sky-100"
      ]}
    >
      <%= case @target do %>
        <% {:ok, %{url: url}} when is_binary(url) -> %>
          <%!-- New tab, like doc_link: record pages have no way back to the note. --%>
          <a href={url} target="_blank" class="min-w-0 truncate hover:underline">{@text}</a>
        <% _ -> %>
          <span class="min-w-0 truncate">{@text}</span>
      <% end %>
      {render_slot(@inner_block)}
    </span>
    """
  end

  defp chip_text(type, {:ok, t}), do: "#{type_label(type)} · #{t.title}"
  defp chip_text(_type, {:error, :restricted}), do: gettext("Restricted record")
  defp chip_text(type, _), do: "(#{gettext("deleted")} #{type_label(type)})"

  attr :id, :string, required: true
  attr :item, :map, required: true, doc: "%{note: Note, d: Notes.feed_details/3 entry}"
  attr :current_company, :map, required: true
  attr :host, :any, default: nil, doc: "{type, id} of the record whose page shows this post"
  attr :relation, :atom, default: nil, doc: ":linked tags a note that only links to the host"
  attr :new_tab, :boolean, default: false, doc: "open the note in a new tab (panels)"
  attr :can_attach, :boolean, default: false
  attr :target, :any, default: nil
  attr :compact, :boolean, default: false, doc: "one row of small thumbnails (panels)"
  attr :detail, :boolean, default: false, doc: "the post page: full text, all files, no links"
  slot :actions, doc: "detail only: controls at the end of the counts row"

  @doc """
  One note as a post — the feed and every notes panel use this, so a note
  looks the same everywhere. On a record's page (`host`), chips naming that
  record are left out: they would only point back at the page you are on.
  """
  def note_post(assigns) do
    note = assigns.item.note
    d = assigns.item.d
    host = assigns.host
    # The first 4 files of any kind; PDFs are tiles in the same grid.
    shown = if assigns.detail, do: note.attachments, else: Enum.take(note.attachments, 4)
    is_host? = fn type, id -> host == {type, id} end

    assigns =
      assign(assigns,
        note: note,
        d: d,
        subject: if(d.subject && !is_host?.(note.subject_type, note.subject_id), do: d.subject),
        links: Enum.reject(d.links, &is_host?.(&1.type, &1.id)),
        thumbs: shown,
        hidden_files: length(note.attachments) - length(shown),
        path: "/companies/#{assigns.current_company.id}/notes/#{note.id}"
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
            {if @detail,
              do: FullCircleWeb.Helpers.format_datetime(@note.inserted_at, @current_company),
              else: "· " <> ago(@note.inserted_at, @current_company)}
          </span>
          <span
            :if={@relation == :linked}
            class="note-linked ml-1 rounded-full border border-sky-400 px-2 text-xs text-sky-800 dark:text-sky-200"
            title={gettext("This note links here; it is about something else.")}
          >
            ↩ {gettext("linked")}
          </span>
          <span
            :if={@note.visibility}
            class="ml-1 rounded-full border border-rose-300 bg-rose-100 px-2 text-xs text-rose-800 dark:border-rose-700 dark:bg-rose-900 dark:text-rose-100"
          >
            🔒 {if Note.private?(@note),
              do: gettext("Private"),
              else: Enum.join(@note.visibility, ", ")}
          </span>
        </div>

        <div :if={@subject || @links != []} class="mt-0.5 flex flex-wrap gap-1">
          <.record_chip :if={@subject} target={@subject} type={@note.subject_type} kind={:subject} />
          <.record_chip :for={l <- @links} target={l.target} type={l.type} />
        </div>

        <div :if={@detail} class="mt-2">
          <div :if={@note.title} class="note-title text-xl font-bold">{@note.title}</div>
          <div phx-no-format class="whitespace-pre-wrap break-words text-lg">{@note.body}</div>
        </div>
        <.post_link :if={!@detail} path={@path} new_tab={@new_tab} class="mt-1 block">
          <div :if={@note.title} class="note-title font-bold">{@note.title}</div>
          <div phx-no-format class="line-clamp-8 whitespace-pre-wrap break-words">{@note.body}</div>
        </.post_link>

        <%!-- Panels sit under a record's form: a row of small thumbnails, names in
             the tooltip. The feed gets the large X-style grid. --%>
        <div :if={@compact and @thumbs != []} class="mt-2 flex items-center gap-1.5">
          <a
            :for={a <- @thumbs}
            href={Attachments.url(a)}
            target="_blank"
            title={a.file_name}
            class="note-thumb block overflow-hidden rounded-lg border border-gray-200 dark:border-gray-700"
          >
            <.file_thumb att={a} class="h-16 w-16" />
          </a>
          <span :if={@hidden_files > 0} class="text-xs text-gray-500">+{@hidden_files}</span>
        </div>
        <div
          :if={!@compact and @thumbs != []}
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
        <div :if={!@compact and @hidden_files > 0} class="mt-1 text-xs text-gray-500">
          + {ngettext("1 more file", "%{count} more files", @hidden_files)}
        </div>

        <div class="mt-2 flex items-center gap-8 text-sm text-gray-500 dark:text-gray-400">
          <.post_link :if={!@detail} path={@path} new_tab={@new_tab} class="flex gap-8">
            <span title={gettext("Notes about this note")}>💬
            <span class="note-replies">{@d.replies}</span></span>
            <span title={gettext("Links")}>🔗 <span class="note-links">{length(@d.links)}</span></span>
            <span title={gettext("Files")}>📎
            <span class="note-files">{length(@note.attachments)}</span></span>
          </.post_link>
          <div :if={@detail} class="flex gap-8">
            <span title={gettext("Notes about this note")}>💬
            <span class="note-replies">{@d.replies}</span></span>
            <span title={gettext("Links")}>🔗 <span class="note-links">{length(@d.links)}</span></span>
            <span title={gettext("Files")}>📎
            <span class="note-files">{length(@note.attachments)}</span></span>
          </div>
          <span :if={@can_attach}>
            <.attach_button note_id={@note.id} current_company={@current_company} />
          </span>
          <div :if={@detail} class="ml-auto flex items-center gap-3">{render_slot(@actions)}</div>
        </div>
      </div>
    </article>
    """
  end

  attr :path, :string, required: true
  attr :new_tab, :boolean, default: false
  attr :class, :any, default: nil
  slot :inner_block, required: true

  # In the feed a post opens in the same tab; in a record's notes panel it
  # opens in a new one so the record stays put (see "Navigation" in the skill).
  defp post_link(%{new_tab: true} = assigns) do
    ~H"""
    <a href={@path} target="_blank" class={@class}>{render_slot(@inner_block)}</a>
    """
  end

  defp post_link(assigns) do
    ~H"""
    <.link navigate={@path} class={@class}>{render_slot(@inner_block)}</.link>
    """
  end
end
