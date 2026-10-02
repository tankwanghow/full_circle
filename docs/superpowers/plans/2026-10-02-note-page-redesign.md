# Note Page Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the note page look and work like the notes feed — an x.com single-post page with inline edit — by extracting one shared write box used by the feed, new note, edit, and every notes panel.

**Architecture:** A new `NoteLive.ComposerComponent` (LiveComponent) owns all write-box state (body, title, subject, links, visibility) and calls `Notes.create_note/3` / `Notes.update_note/4` itself, telling its host what happened. `RecordPickerComponent` gains a `notify` target so it can report picks to the composer. `note_post/1` gains a `detail` variant for the single-post view. `NoteLive.Form` is rewritten into view / edit modes around them; `NotesPanelComponent` gets a `:thread` layout and uses the composer for quick-add.

**Tech Stack:** Elixir 1.19.5, Phoenix 1.8, LiveView 1.2, Tailwind 4.

**Spec:** `docs/superpowers/specs/2026-10-02-note-page-redesign-design.md`. Read `.claude/skills/notes.md` first (sections: Visibility values, Versions, Attachments, One post component, Feed, Two note forms on one page, Record chips, Navigation, Dark theme).

## Global Constraints

- UI change only: `Notes` context, versions, attachments controller and `note_attach.js`, link add/remove, rights and visibility rules are unchanged.
- The write box is ONE component, `FullCircleWeb.NoteLive.ComposerComponent`; no host keeps its own note form.
- Every composer input id is prefixed with the composer `id`; two composers on one page never share an id (notes skill "Two note forms on one page").
- Composer root element id is `"#{id}-box"` (never the bare `id`: a panel and its composer share the component id — allowed, LiveComponent ids are unique per module — and the panel's `<section id={@id}>` keeps its DOM id).
- Composer DOM ids: form `"#{id}-form"`, body textarea `"#{id}_body_#{rev}"`, title `"#{id}_title"`, visibility chips prefix `"#{id}-visibility"`, picker toggle `"#{id}-open-picker"`, picker component `"#{id}-picker"`, clear-subject `"#{id}-clear-subject"`, cancel `"#{id}-cancel"`, error line `"#{id}-error"`; saved-link remove buttons keep `"remove-link-#{link_id}"`.
- Composer ids used by hosts: feed `"compose"`, note page edit/new `"note"`, panel = the panel's own id (e.g. `"notes-panel"`, `"task-notes"`, `"notes-modal-panel"`).
- Note page routes: `/notes/new` (`:new`), `/notes/:note_id` (`:show`, post view), `/notes/:note_id/edit` (`:edit`, opens in edit mode when the user may edit, else post view). `Linkable.url("Note", id, company)` and `note_post`'s link → `/companies/:cid/notes/:id`.
- Task panels: Private by default, no role chips, hint "Everyone who can see this task can read its notes." (unchanged behaviour, now passed into the composer).
- Light and dark theme must both look right (`decluttered-index.md` dark-mode trap: prefer slate / gray-*-with-dark: pairs already used by the feed; choose selected states on the server).
- Never run bare `mix format`; format only touched files. Never `mix gettext.extract --merge`; append zh msgids by hand after checking they're absent.
- Flash kind for warnings is `:warn`.
- Commit on `master`; every commit message ends with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. **Half-typed text lost on host re-render** — the feed / note page re-render on PubSub or flash; the composer must not reset its body, subject or links unless it posted or was cancelled. Tested in Task 1 ("host re-render keeps typed text").
2. **A pick reaching the wrong composer** — with the edit composer and the reply composer on one note page, a record picked in one must not land in the other. Tested in Task 6 ("pick goes to the edit box only").
3. **Stale edit losing the user's words** — saving after someone else edited must keep the typed body and title and show the warning. Tested in Task 2.
4. **Attach after inline edit** — uploading a file while in edit mode must still refresh the file tiles (the `note-attach:done` hand-off reaches the LiveView). Tested in Task 6 ("attachment_uploaded refreshes tiles in edit mode").
5. **Reader opening /edit** — a user who can read but not edit opening `/notes/:id/edit` gets the post view, no write box, no Delete. Tested in Task 6.

---

## File Structure

| File | Responsibility |
|---|---|
| `lib/full_circle_web/live/note_live/composer_component.ex` (new) | the one write box |
| `lib/full_circle_web/live/note_live/record_picker_component.ex` | `notify` target for picks |
| `lib/full_circle_web/live/note_live/index.ex` | feed uses the composer |
| `lib/full_circle_web/live/note_live/notes_panel_component.ex` | composer quick-add; `:card` / `:thread` layout |
| `lib/full_circle_web/components/note_components.ex` | `note_post` `detail` variant; post link → `/notes/:id` |
| `lib/full_circle/linkable.ex` | `url("Note", …)` → `/notes/:id` |
| `lib/full_circle_web/router.ex` | `/notes/:note_id` → `:show` |
| `lib/full_circle_web/live/note_live/form.ex` | rewritten note page |
| tests: `test/full_circle_web/live/note_composer_test.exs` (new), `note_live_test.exs`, `notes_panel_live_test.exs`, `task_live_test.exs`, `linkable_test.exs` |
| docs: `.claude/skills/notes.md`, `priv/gettext/zh/LC_MESSAGES/default.po` |

---

### Task 1: Composer component (create modes) and picker `notify`

**Files:**
- Create: `lib/full_circle_web/live/note_live/composer_component.ex`
- Modify: `lib/full_circle_web/live/note_live/record_picker_component.ex`
- Create: `test/full_circle_web/live/note_composer_test.exs`

**Interfaces:**
- Produces `FullCircleWeb.NoteLive.ComposerComponent` (`live_component`). Attrs (all optional unless noted):
  - `id` (required), `current_company`, `current_user` (required)
  - `mode`: `:new` (default) | `:edit` (Task 2)
  - `note`: `%Note{}` for `:edit`
  - `initial_subject`: `%{type, id, title}` prefill (`:new`)
  - `fixed_subject`: `{type, id}` — the note is always about this record; no subject picker
  - `full`: `false` — true shows the title input and link chips / "+ link a record"
  - `roles_open`: defaults to `full` — show visibility chips expanded (else a folded pill)
  - `default_visibility`: `nil`; `roles`: `true`; `private_title`: `nil`; `hint`: `nil`
  - `placeholder` ("Write a note…"), `submit_label` ("Post"), `avatar` (false), `cancellable` (false), `full_form_path` (nil), `class` (nil)
  - `notify`: `:liveview` (default) → `send(self(), {:composer, id, event})`; or `{module, component_id}` → `send_update(module, id: component_id, composer: {id, event})`
  - events: `{:saved, mode, %Note{}}`, `:cancelled`
- `RecordPickerComponent` new attr `notify`: `nil` (default, unchanged `send(self(), {:record_picked, id, picked})`) or `{module, component_id}` → `send_update(module, id: component_id, picked: {picker_id, picked})`.

- [ ] **Step 1: Write the failing tests**

Create `test/full_circle_web/live/note_composer_test.exs`:

```elixir
defmodule FullCircleWeb.NoteComposerTest do
  use FullCircleWeb.ConnCase

  import Phoenix.LiveViewTest
  import FullCircle.SysFixtures
  import FullCircle.UserAccountsFixtures
  import FullCircle.BillingFixtures
  import FullCircle.NotesFixtures

  alias FullCircle.Notes.Note

  # A bare LiveView hosting one composer; it records the last composer event.
  defmodule Host do
    use FullCircleWeb, :live_view

    def mount(_params, session, socket) do
      {:ok,
       assign(socket,
         current_company: FullCircle.Repo.get!(FullCircle.Sys.Company, session["company_id"]),
         current_user: FullCircle.Repo.get!(FullCircle.UserAccounts.User, session["user_id"]),
         opts: session["opts"] || %{},
         last: nil,
         tick: 0
       ), layout: false}
    end

    def handle_info({:composer, _id, event}, socket), do: {:noreply, assign(socket, last: event)}

    def handle_event("tick", _, socket), do: {:noreply, assign(socket, tick: socket.assigns.tick + 1)}

    def render(assigns) do
      ~H"""
      <button id="tick" phx-click="tick">{@tick}</button>
      <.live_component
        module={FullCircleWeb.NoteLive.ComposerComponent}
        id="c"
        current_company={@current_company}
        current_user={@current_user}
        {Map.new(@opts, fn {k, v} -> {String.to_existing_atom(k), v} end)}
      />
      <div id="last">{inspect(@last)}</div>
      """
    end
  end

  setup %{conn: conn} do
    admin = user_fixture()
    comp = company_fixture(admin, %{})
    %{conn: log_in_user(conn, admin), admin: admin, comp: comp}
  end

  defp host(conn, comp, admin, opts \\ %{}) do
    {:ok, lv, _} =
      live_isolated(conn, Host,
        session: %{"company_id" => comp.id, "user_id" => admin.id, "opts" => opts}
      )

    lv
  end

  test "posts a note, tells the host and clears itself", %{conn: conn, admin: admin, comp: comp} do
    lv = host(conn, comp, admin)
    lv |> form("#c-form", %{"note" => %{"body" => "Gate 2 lock is broken"}}) |> render_submit()

    [note] = FullCircle.Repo.all(Note)
    assert note.body == "Gate 2 lock is broken"
    assert render(lv) =~ "{:saved, :new"
    refute has_element?(lv, "#c-form textarea", "Gate 2 lock is broken")
  end

  test "blank body shows the error inside the box", %{conn: conn, admin: admin, comp: comp} do
    lv = host(conn, comp, admin)
    html = lv |> form("#c-form", %{"note" => %{"body" => ""}}) |> render_submit()
    assert html =~ "can&#39;t be blank"
    assert FullCircle.Repo.all(Note) == []
  end

  test "host re-render keeps typed text", %{conn: conn, admin: admin, comp: comp} do
    lv = host(conn, comp, admin)
    lv |> form("#c-form", %{"note" => %{"body" => "half typed"}}) |> render_change()
    lv |> element("#tick") |> render_click()
    assert has_element?(lv, "#c-form textarea", "half typed")
  end

  test "subject picked through the picker is saved", %{conn: conn, admin: admin, comp: comp} do
    c = contact_fixture(comp, admin, %{"name" => "Kedai Mei"})
    lv = host(conn, comp, admin)

    lv |> element("#c-open-picker") |> render_click()
    lv |> form("#c-picker form", %{"type" => "Contact", "terms" => "Mei"}) |> render_change()
    lv |> element("#c-picker-pick-#{c.id}") |> render_click()
    assert render(lv) =~ "Kedai Mei"

    lv |> form("#c-form", %{"note" => %{"body" => "orders every Monday"}}) |> render_submit()
    [note] = FullCircle.Repo.all(Note)
    assert {note.subject_type, note.subject_id} == {"Contact", c.id}
  end

  test "full mode: title, queued links, expanded role chips", %{conn: conn, admin: admin, comp: comp} do
    ali = contact_fixture(comp, admin, %{"name" => "Ali Welding"})
    mei = contact_fixture(comp, admin, %{"name" => "Kedai Mei"})
    lv = host(conn, comp, admin, %{"full" => true})

    assert has_element?(lv, "label.role-chip", "manager")

    for {c, terms} <- [{ali, "Ali"}, {mei, "Mei"}] do
      lv |> element("#c-open-picker") |> render_click()
      lv |> form("#c-picker form", %{"type" => "Contact", "terms" => terms}) |> render_change()
      lv |> element("#c-picker-pick-#{c.id}") |> render_click()
    end

    lv
    |> form("#c-form", %{
      "note" => %{"title" => "Welders", "body" => "both weld", "visibility" => ["manager"]}
    })
    |> render_submit()

    [note] = FullCircle.Repo.all(Note)
    assert note.title == "Welders"
    assert note.subject_id == ali.id
    assert note.visibility == ["manager"]
    assert [%{id: id}] = FullCircle.Notes.list_links(note, comp, admin)
    assert id == mei.id
  end

  test "fixed subject: no picker, note is about the record", %{conn: conn, admin: admin, comp: comp} do
    c = contact_fixture(comp, admin)
    lv = host(conn, comp, admin, %{"fixed_subject" => {"Contact", c.id}})
    refute has_element?(lv, "#c-open-picker")
    lv |> form("#c-form", %{"note" => %{"body" => "pays late"}}) |> render_submit()
    [note] = FullCircle.Repo.all(Note)
    assert {note.subject_type, note.subject_id} == {"Contact", c.id}
  end

  test "Private default and no role chips (task panels)", %{conn: conn, admin: admin, comp: comp} do
    lv =
      host(conn, comp, admin, %{
        "roles_open" => true,
        "roles" => false,
        "default_visibility" => ["admin"],
        "hint" => "Everyone who can see this task can read its notes."
      })

    assert has_element?(lv, "#c-visibility-private[data-selected]")
    refute has_element?(lv, "label.role-chip", "manager")
    assert render(lv) =~ "Everyone who can see this task can read its notes."
  end
end
```

(The picker's unchanged default — `send(self(), {:record_picked, …})` — stays covered by the existing note page tests until Task 6.)

- [ ] **Step 2: Run to verify failure**

Run: `mix test test/full_circle_web/live/note_composer_test.exs`
Expected: FAIL — `FullCircleWeb.NoteLive.ComposerComponent` is undefined.

- [ ] **Step 3: Add `notify` to the picker**

In `lib/full_circle_web/live/note_live/record_picker_component.ex`, in `update/2` add `|> assign_new(:notify, fn -> nil end)` and replace the `send(self(), …)` in `handle_event("pick", …)` with:

```elixir
        case socket.assigns.notify do
          {module, component_id} ->
            send_update(module,
              id: component_id,
              picked: {socket.assigns.id, %{type: r.type, id: r.id, title: r.title}}
            )

          nil ->
            send(
              self(),
              {:record_picked, socket.assigns.id, %{type: r.type, id: r.id, title: r.title}}
            )
        end
```

Update the moduledoc: "Sends `{:record_picked, id, picked}` to the parent LiveView, or — with `notify: {module, id}` — `send_update`s that component with `picked: {picker_id, picked}`."

- [ ] **Step 4: Write the composer**

Create `lib/full_circle_web/live/note_live/composer_component.ex`:

```elixir
defmodule FullCircleWeb.NoteLive.ComposerComponent do
  @moduledoc """
  The one note write box: the feed's post box, a new note, editing a note in
  place, and the quick-add / reply box of every notes panel. It owns its form
  state, saves through `Notes`, and tells its host `{:saved, mode, note}` or
  `:cancelled` (see `notify`). Input ids are prefixed with the component id, so
  several boxes can share a page. Contract: `.claude/skills/notes.md`.
  """
  use FullCircleWeb, :live_component

  import FullCircleWeb.NoteComponents

  alias FullCircle.{Linkable, Notes}
  alias FullCircle.Notes.Note
  alias FullCircleWeb.NoteLive.RecordPickerComponent

  @defaults [
    mode: :new,
    note: nil,
    initial_subject: nil,
    fixed_subject: nil,
    full: false,
    roles_open: nil,
    default_visibility: nil,
    roles: true,
    private_title: nil,
    hint: nil,
    placeholder: nil,
    submit_label: nil,
    avatar: false,
    cancellable: false,
    full_form_path: nil,
    class: nil,
    notify: :liveview
  ]

  # A pick from this box's picker (RecordPickerComponent notify).
  @impl true
  def update(%{picked: {_picker_id, picked}}, socket), do: {:ok, pick(socket, picked)}

  def update(assigns, socket) do
    first? = is_nil(socket.assigns[:rev])

    socket =
      Enum.reduce(@defaults, assign(socket, assigns), fn {k, v}, s -> assign_new(s, k, fn -> v end) end)

    {:ok, if(first?, do: reset(socket), else: socket)}
  end

  # --- state ----------------------------------------------------------------

  defp reset(socket) do
    rev = (socket.assigns[:rev] || 0) + 1

    socket
    |> assign(
      rev: rev,
      params: %{},
      error: nil,
      picker_open: false,
      show_roles: roles_open?(socket.assigns),
      subject: initial_subject(socket),
      links: initial_links(socket)
    )
    |> assign(form: to_form(Notes.change_note(base_note(socket.assigns)), id: "#{socket.assigns.id}_note"))
  end

  defp roles_open?(%{roles_open: nil, full: full}), do: full
  defp roles_open?(%{roles_open: open}), do: open

  defp base_note(%{mode: :edit, note: %Note{} = note}), do: note
  defp base_note(%{default_visibility: v}), do: %Note{visibility: v}

  defp initial_subject(%{assigns: %{mode: :edit, note: %Note{subject_type: nil}}}), do: nil

  defp initial_subject(%{assigns: %{mode: :edit, note: %Note{} = n} = a}) do
    case Linkable.resolve(n.subject_type, n.subject_id, a.current_company, a.current_user) do
      {:ok, t} -> %{type: n.subject_type, id: n.subject_id, title: t.title}
      _ -> %{type: n.subject_type, id: n.subject_id, title: gettext("(unavailable)")}
    end
  end

  defp initial_subject(socket), do: socket.assigns.initial_subject

  defp initial_links(%{assigns: %{mode: :edit, note: %Note{} = n} = a}),
    do: Notes.list_links(n, a.current_company, a.current_user)

  defp initial_links(_socket), do: []

  defp subject_attrs(%{fixed_subject: {t, id}}), do: %{"subject_type" => t, "subject_id" => id}
  defp subject_attrs(%{subject: %{type: t, id: id}}), do: %{"subject_type" => t, "subject_id" => id}
  defp subject_attrs(_), do: %{"subject_type" => nil, "subject_id" => nil}

  defp change(socket, params) do
    cs =
      socket.assigns
      |> base_note()
      |> Notes.change_note(Map.merge(params, subject_attrs(socket.assigns)))
      |> Map.put(:action, :validate)

    assign(socket, form: to_form(cs, id: "#{socket.assigns.id}_note"), params: params)
  end

  defp notify(%{assigns: %{notify: :liveview, id: id}}, event), do: send(self(), {:composer, id, event})

  defp notify(%{assigns: %{notify: {module, cid}, id: id}}, event),
    do: send_update(module, id: cid, composer: {id, event})

  # --- events ---------------------------------------------------------------

  @impl true
  def handle_event("validate", %{"note" => params}, socket), do: {:noreply, change(socket, params)}

  def handle_event("visibility_everyone", _, socket),
    do: {:noreply, change(socket, Map.put(socket.assigns.params, "visibility", [""]))}

  def handle_event("visibility_private", _, socket),
    do: {:noreply, change(socket, Map.put(socket.assigns.params, "visibility", Note.private_visibility()))}

  def handle_event("toggle_roles", _, socket),
    do: {:noreply, assign(socket, show_roles: !socket.assigns.show_roles)}

  def handle_event("toggle_picker", _, socket),
    do: {:noreply, assign(socket, picker_open: !socket.assigns.picker_open)}

  def handle_event("clear_subject", _, socket), do: {:noreply, assign(socket, subject: nil)}

  def handle_event("remove_queued_link", %{"id" => id}, socket),
    do: {:noreply, assign(socket, links: Enum.reject(socket.assigns.links, &(&1.id == id)))}

  def handle_event("cancel", _, socket) do
    notify(socket, :cancelled)
    {:noreply, reset(socket)}
  end

  def handle_event("save", %{"note" => params}, socket) do
    %{current_company: com, current_user: user, mode: mode} = socket.assigns
    params = Map.merge(params, subject_attrs(socket.assigns))

    result =
      case mode do
        :edit ->
          Notes.update_note(socket.assigns.note, params, com, user)

        _ ->
          links = Enum.map(socket.assigns.links, &%{"type" => &1.type, "id" => &1.id})
          Notes.create_note(Map.put(params, "links", links), com, user)
      end

    case result do
      {:ok, note} ->
        notify(socket, {:saved, mode, note})
        {:noreply, reset(socket)}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, assign(socket, form: to_form(cs, id: "#{socket.assigns.id}_note"), params: params)}

      error ->
        {:noreply, socket |> change(params) |> assign(error: error_text(error))}
    end
  end

  defp error_text({:error, :stale}),
    do: gettext("someone else changed this note — reload to see their version")

  defp error_text({:error, {:link, :not_found}}), do: gettext("A linked record no longer exists.")
  defp error_text(_), do: gettext("Not Authorise.")

  # The first pick sets the subject; later picks (full mode) are links —
  # queued on a new note, added straight away on a saved one.
  defp pick(socket, picked) do
    socket = assign(socket, picker_open: false)
    %{subject: subject, mode: mode, note: note} = socket.assigns

    cond do
      is_nil(subject) and mode == :edit and picked.type == "Note" and picked.id == note.id ->
        assign(socket, error: gettext("A note cannot be about itself."))

      is_nil(subject) ->
        assign(socket, subject: picked, error: nil)

      picked.type == subject.type and picked.id == subject.id ->
        socket

      mode == :edit ->
        add_saved_link(socket, picked)

      true ->
        assign(socket, links: Enum.uniq_by(socket.assigns.links ++ [picked], &{&1.type, &1.id}))
    end
  end

  # Task 2 fills this in (links on a saved note apply immediately).
  defp add_saved_link(socket, _picked), do: socket

  # --- render ---------------------------------------------------------------

  defp roles_of(form), do: Ecto.Changeset.get_field(form.source, :visibility) || []

  defp visibility_label(roles) do
    cond do
      roles == [] -> "👥 " <> gettext("Everyone")
      roles == Note.private_visibility() -> "🔒 " <> gettext("Private")
      true -> "🔒 " <> Enum.join(roles, ", ")
    end
  end

  defp chip_target(%{target: target}, _company), do: target

  defp chip_target(%{type: type, id: id, title: title}, company),
    do: {:ok, %{title: title, url: Linkable.url(type, id, company)}}

  defp errors(form) do
    Enum.map(
      form[:body].errors ++ form[:subject_id].errors ++ form[:subject_type].errors ++ form[:visibility].errors,
      &FullCircleWeb.CoreComponents.translate_error/1
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={"#{@id}-box"} class={["flex gap-3", @class]}>
      <.avatar :if={@avatar} email={@current_user.email} />
      <div class="min-w-0 flex-1">
        <.form
          for={@form}
          id={"#{@id}-form"}
          phx-change="validate"
          phx-submit="save"
          phx-target={@myself}
          autocomplete="off"
        >
          <input
            :if={@full}
            type="text"
            id={"#{@id}_title"}
            name="note[title]"
            value={@form[:title].value}
            placeholder={gettext("Title (optional)")}
            class="w-full border-0 bg-transparent p-1 text-lg font-bold placeholder-gray-500 focus:ring-0"
          />
          <textarea
            id={"#{@id}_body_#{@rev}"}
            name="note[body]"
            rows={if @full, do: 6, else: 2}
            placeholder={@placeholder || gettext("Write a note…")}
            class="w-full resize-y border-0 bg-transparent p-1 text-lg placeholder-gray-500 focus:ring-0"
          >{Phoenix.HTML.Form.normalize_value("textarea", @form[:body].value)}</textarea>
          <.error :for={msg <- errors(@form)}>{msg}</.error>
          <p :if={@error} id={"#{@id}-error"} class="text-sm text-rose-700 dark:text-rose-300">
            {@error}
          </p>

          <div :if={@show_roles} class="flex flex-wrap items-center gap-1 pb-2 text-xs">
            <.visibility_chips
              visibility={roles_of(@form)}
              id_prefix={"#{@id}-visibility"}
              target={@myself}
              roles={@roles}
              private_title={@private_title}
            />
          </div>
          <div :if={!@show_roles}>
            <input type="hidden" name="note[visibility][]" value="" />
            <input :for={role <- roles_of(@form)} type="hidden" name="note[visibility][]" value={role} />
          </div>
          <p :if={@hint} class="pb-1 text-xs text-slate-500 dark:text-slate-400">{@hint}</p>

          <div class="flex flex-wrap items-center gap-1 border-t border-gray-200 pt-2 dark:border-gray-700">
            <.record_chip
              :if={@subject && !@fixed_subject}
              type={@subject.type}
              target={chip_target(@subject, @current_company)}
              kind={:subject}
            >
              <button
                type="button"
                id={"#{@id}-clear-subject"}
                phx-click="clear_subject"
                phx-target={@myself}
                title={gettext("Clear")}
                class="shrink-0"
              >
                ✕
              </button>
            </.record_chip>
            <.record_chip :for={l <- @links} type={l.type} target={chip_target(l, @current_company)}>
              <button
                :if={@mode == :edit}
                type="button"
                id={"remove-link-#{l.link_id}"}
                phx-click="remove_link"
                phx-value-id={l.link_id}
                phx-target={@myself}
                title={gettext("Remove")}
                class="shrink-0"
              >
                ✕
              </button>
              <button
                :if={@mode != :edit}
                type="button"
                phx-click="remove_queued_link"
                phx-value-id={l.id}
                phx-target={@myself}
                title={gettext("Remove")}
                class="shrink-0"
              >
                ✕
              </button>
            </.record_chip>
            <button
              :if={!@fixed_subject and (is_nil(@subject) or @full)}
              id={"#{@id}-open-picker"}
              type="button"
              phx-click="toggle_picker"
              phx-target={@myself}
              class={[
                "rounded-full border px-2 text-xs",
                if(is_nil(@subject),
                  do: "border-amber-400 bg-amber-50 text-amber-900 dark:border-amber-600 dark:bg-amber-950 dark:text-amber-100",
                  else: "border-dashed border-gray-400 text-gray-600 dark:border-gray-500 dark:text-gray-300"
                )
              ]}
            >
              ＋ {if @subject, do: gettext("link a record"), else: gettext("about…")}
            </button>
            <button
              :if={!@show_roles}
              type="button"
              phx-click="toggle_roles"
              phx-target={@myself}
              class="rounded-full border border-gray-300 px-2 text-xs text-gray-600 dark:border-gray-600 dark:text-gray-300"
            >
              {visibility_label(roles_of(@form))} ▾
            </button>
            <span class="ml-auto flex items-center gap-2">
              <.link
                :if={@full_form_path}
                navigate={@full_form_path}
                class="text-xs text-gray-500 hover:underline"
              >
                {gettext("Full form")}
              </.link>
              <button
                :if={@cancellable}
                type="button"
                id={"#{@id}-cancel"}
                phx-click="cancel"
                phx-target={@myself}
                class="text-sm text-gray-500 hover:underline"
              >
                {gettext("Cancel")}
              </button>
              <button
                type="submit"
                class="rounded-full bg-sky-500 px-4 py-1 text-sm font-bold text-white hover:bg-sky-600"
              >
                {@submit_label || gettext("Post")}
              </button>
            </span>
          </div>
        </.form>
        <div :if={@picker_open} class="mt-2">
          <.live_component
            module={RecordPickerComponent}
            id={"#{@id}-picker"}
            notify={{__MODULE__, @id}}
            label={
              if @subject,
                do: gettext("Link other records"),
                else: gettext("What is this note about?")
            }
            current_company={@current_company}
            current_user={@current_user}
          />
        </div>
      </div>
    </div>
    """
  end
end
```

- [ ] **Step 5: Run the tests**

Run: `mix test test/full_circle_web/live/note_composer_test.exs`
Expected: PASS. If the Host's `{Map.new(...)}` dynamic-attrs spread fails to compile, build the attrs map in `mount` (convert `"full"` → `:full` etc.) and pass `{@attrs}` instead.

- [ ] **Step 6: Commit**

```bash
mix format lib/full_circle_web/live/note_live/composer_component.ex lib/full_circle_web/live/note_live/record_picker_component.ex test/full_circle_web/live/note_composer_test.exs
git add lib/full_circle_web/live/note_live/composer_component.ex lib/full_circle_web/live/note_live/record_picker_component.ex test/full_circle_web/live/note_composer_test.exs
git commit -m "feat(notes): one composer component for every note write box

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Composer edit mode

**Files:**
- Modify: `lib/full_circle_web/live/note_live/composer_component.ex`
- Test: `test/full_circle_web/live/note_composer_test.exs` (append)

**Interfaces:**
- Consumes: Task 1 composer.
- Produces: `mode: :edit` with `note: %Note{}` (preloaded `:author, :updated_by, :attachments` as `Notes.get_note/3` returns) — prefills title/body/visibility/subject/links; Save → `Notes.update_note/4` → `{:saved, :edit, note}`; stale → keeps text + error line; `cancellable` → `:cancelled`; links on a saved note add/remove immediately via `Notes.add_link/5` / `Notes.remove_link/4`.

- [ ] **Step 1: Write the failing tests**

Append inside `FullCircleWeb.NoteComposerTest`:

```elixir
  describe "edit mode" do
    defp edit_host(conn, comp, admin, note) do
      note = FullCircle.Notes.get_note(note.id, comp, admin)
      host(conn, comp, admin, %{"mode" => :edit, "note" => note, "full" => true, "cancellable" => true})
    end

    test "prefills and saves, writing one version", %{conn: conn, admin: admin, comp: comp} do
      c = contact_fixture(comp, admin, %{"name" => "Ah Seng"})

      note =
        note_fixture(comp, admin, %{
          "title" => "T",
          "body" => "v1",
          "subject_type" => "Contact",
          "subject_id" => c.id,
          "visibility" => ["manager"]
        })

      lv = edit_host(conn, comp, admin, note)
      assert has_element?(lv, "#c-form textarea", "v1")
      assert has_element?(lv, ~s{#c_title[value="T"]})
      assert render(lv) =~ "Ah Seng"
      assert has_element?(lv, "label.role-chip[data-selected]", "manager")

      lv |> form("#c-form", %{"note" => %{"body" => "v2"}}) |> render_submit()
      assert render(lv) =~ "{:saved, :edit"
      assert FullCircle.Repo.get!(Note, note.id).body == "v2"
      assert [%{body: "v1"}] = FullCircle.Repo.all(FullCircle.Notes.NoteVersion)
    end

    test "a stale save keeps the typed text and warns", %{conn: conn, admin: admin, comp: comp} do
      note = note_fixture(comp, admin, %{"body" => "v1"})
      lv = edit_host(conn, comp, admin, note)
      {:ok, _} = FullCircle.Notes.update_note(note, %{"body" => "someone else"}, comp, admin)

      html =
        lv
        |> form("#c-form", %{"note" => %{"title" => "my title", "body" => "my text"}})
        |> render_submit()

      assert html =~ "someone else changed this note"
      assert has_element?(lv, "#c-form textarea", "my text")
      assert has_element?(lv, ~s{#c_title[value="my title"]})
    end

    test "cancel tells the host and saves nothing", %{conn: conn, admin: admin, comp: comp} do
      note = note_fixture(comp, admin, %{"body" => "v1"})
      lv = edit_host(conn, comp, admin, note)
      lv |> form("#c-form", %{"note" => %{"body" => "draft"}}) |> render_change()
      lv |> element("#c-cancel") |> render_click()
      assert render(lv) =~ ":cancelled"
      assert FullCircle.Repo.get!(Note, note.id).body == "v1"
    end

    test "links on a saved note apply straight away", %{conn: conn, admin: admin, comp: comp} do
      ali = contact_fixture(comp, admin, %{"name" => "Ali Welding"})
      mei = contact_fixture(comp, admin, %{"name" => "Kedai Mei"})

      note =
        note_fixture(comp, admin, %{"body" => "b", "subject_type" => "Contact", "subject_id" => ali.id})

      lv = edit_host(conn, comp, admin, note)
      lv |> element("#c-open-picker") |> render_click()
      lv |> form("#c-picker form", %{"type" => "Contact", "terms" => "Mei"}) |> render_change()
      lv |> element("#c-picker-pick-#{mei.id}") |> render_click()

      assert [link] = FullCircle.Notes.list_links(note, comp, admin)
      assert render(lv) =~ "Kedai Mei"

      lv |> element("#remove-link-#{link.link_id}") |> render_click()
      assert FullCircle.Notes.list_links(note, comp, admin) == []
      refute render(lv) =~ "Kedai Mei"
    end

    test "linking a note to itself says why", %{conn: conn, admin: admin, comp: comp} do
      ali = contact_fixture(comp, admin, %{"name" => "Ali Welding"})

      note =
        note_fixture(comp, admin, %{"body" => "self", "subject_type" => "Contact", "subject_id" => ali.id})

      lv = edit_host(conn, comp, admin, note)
      lv |> element("#c-open-picker") |> render_click()
      lv |> form("#c-picker form", %{"type" => "Note", "terms" => "self"}) |> render_change()
      lv |> element("#c-picker-pick-#{note.id}") |> render_click()
      assert render(lv) =~ "cannot link to itself"
    end

    test "clearing the subject saves the note about nothing", %{conn: conn, admin: admin, comp: comp} do
      ali = contact_fixture(comp, admin)

      note =
        note_fixture(comp, admin, %{"body" => "b", "subject_type" => "Contact", "subject_id" => ali.id})

      lv = edit_host(conn, comp, admin, note)
      lv |> element("#c-clear-subject") |> render_click()
      lv |> form("#c-form", %{"note" => %{"body" => "b2"}}) |> render_submit()
      assert FullCircle.Repo.get!(Note, note.id).subject_id == nil
    end
  end
```

- [ ] **Step 2: Run to verify failure**

Run: `mix test test/full_circle_web/live/note_composer_test.exs`
Expected: FAIL — links are not added (`add_saved_link` is a stub) and `"remove_link"` is not handled.

- [ ] **Step 3: Implement**

In `composer_component.ex` replace the `add_saved_link/2` stub and add a `remove_link` handler (before `defp error_text`):

```elixir
  defp add_saved_link(socket, picked) do
    %{note: note, current_company: com, current_user: user} = socket.assigns

    case Notes.add_link(note, picked.type, picked.id, com, user) do
      {:ok, _} ->
        assign(socket, links: Notes.list_links(note, com, user), error: nil)

      # The changeset names the rule ("cannot link to itself", "already linked").
      {:error, %Ecto.Changeset{errors: [{_field, error} | _]}} ->
        assign(socket, error: FullCircleWeb.CoreComponents.translate_error(error))

      _ ->
        assign(socket, error: gettext("Could not link that record."))
    end
  end
```

```elixir
  def handle_event("remove_link", %{"id" => link_id}, socket) do
    %{note: note, current_company: com, current_user: user} = socket.assigns
    Notes.remove_link(note, link_id, com, user)
    {:noreply, assign(socket, links: Notes.list_links(note, com, user))}
  end
```

(`handle_event("remove_link", …)` goes with the other `handle_event` clauses.)

- [ ] **Step 4: Run the tests**

Run: `mix test test/full_circle_web/live/note_composer_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
mix format lib/full_circle_web/live/note_live/composer_component.ex test/full_circle_web/live/note_composer_test.exs
git add lib/full_circle_web/live/note_live/composer_component.ex test/full_circle_web/live/note_composer_test.exs
git commit -m "feat(notes): composer edit mode with stale-safe save and live links

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Feed uses the composer

**Files:**
- Modify: `lib/full_circle_web/live/note_live/index.ex`
- Test: `test/full_circle_web/live/note_live_test.exs`

**Interfaces:**
- Consumes: composer (`id="compose"`, `avatar`, `full_form_path`, notify `:liveview`).
- Produces: the feed handles `{:composer, "compose", {:saved, :new, note}}` by stream-inserting the note at the top.

- [ ] **Step 1: Update the existing test ids (they define the new contract)**

In `test/full_circle_web/live/note_live_test.exs`, test "the post box can set what the note is about": replace `element("#compose-about")` with `element("#compose-open-picker")`. Everything else in the feed tests (`#compose-form`, `#compose-picker form`, `#compose-picker-pick-…`) keeps its id.

- [ ] **Step 2: Run to verify failure**

Run: `mix test test/full_circle_web/live/note_live_test.exs`
Expected: FAIL — `#compose-open-picker` does not exist yet.

- [ ] **Step 3: Replace the inline post box**

In `lib/full_circle_web/live/note_live/index.ex`:
1. Delete from `mount/3` the assigns `compose_subject`, `compose_picker`, `compose_roles` and the `|> reset_compose()` call.
2. Delete every `handle_event("compose_…", …)`, `handle_event("visibility_everyone" | "visibility_private", …)`, the `handle_info({:record_picked, "compose-picker", …})` clause, and the private helpers `reset_compose/1`, `compose_form/1`, `compose_change/2`, `compose_roles/1`.
3. Add:

```elixir
  # The post box (ComposerComponent) saved a note: it goes on top of the feed.
  @impl true
  def handle_info({:composer, "compose", {:saved, :new, note}}, socket) do
    %{current_company: com, current_user: user} = socket.assigns
    note = Repo.preload(note, [:author, :attachments], force: true)

    {:noreply,
     socket
     |> stream_insert(:notes, feed_item(note, Notes.feed_details([note], com, user)), at: 0)
     |> assign(empty?: false)}
  end

  def handle_info({:composer, _id, _event}, socket), do: {:noreply, socket}
```

4. In `render/1`, replace the whole post-box `<div :if={@can_create} class="flex gap-3 border-b …"> … </div>` block with:

```heex
      <div :if={@can_create} class="border-b border-gray-200 px-4 py-3 dark:border-gray-700">
        <.live_component
          module={FullCircleWeb.NoteLive.ComposerComponent}
          id="compose"
          avatar
          full_form_path={~p"/companies/#{@current_company.id}/notes/new"}
          current_company={@current_company}
          current_user={@current_user}
        />
      </div>
```

5. Remove now-unused aliases (`Note`, `RecordPickerComponent`) if the compiler warns.

- [ ] **Step 4: Run the tests**

Run: `mix test test/full_circle_web/live/note_live_test.exs test/full_circle_web/live/note_composer_test.exs`
Expected: PASS (the note-page tests in this file still pass — the note page is untouched until Task 6). `mix compile --force` shows no warnings.

- [ ] **Step 5: Commit**

```bash
mix format lib/full_circle_web/live/note_live/index.ex test/full_circle_web/live/note_live_test.exs
git add lib/full_circle_web/live/note_live/index.ex test/full_circle_web/live/note_live_test.exs
git commit -m "refactor(notes): feed post box is the shared composer

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Notes panel quick-add via the composer; `:thread` layout

**Files:**
- Modify: `lib/full_circle_web/live/note_live/notes_panel_component.ex`
- Test: `test/full_circle_web/live/notes_panel_live_test.exs` (append), existing panel/task tests must stay green

**Interfaces:**
- Consumes: composer with `notify: {NotesPanelComponent, panel_id}`, `fixed_subject`, `roles_open`, `cancellable`.
- Produces: `NotesPanelComponent` attr `layout` — `:card` (default; header with "+ Note" toggling the composer, Cancel closes it) or `:thread` (no card frame/header; composer always open with avatar, placeholder "Post your reply…", submit "Reply"). Ids unchanged: `"#{id}-new"`, `"#{id}-form"`, `"#{id}-visibility-…"`, `"#{id}-note-…"`.

- [ ] **Step 1: Write the failing test**

Append to `FullCircleWeb.NotesPanelLiveTest` (it renders the panel via a host page; use the Contact edit page for `:card` and a direct `live_isolated` host for `:thread`):

```elixir
  describe "panel composer" do
    defmodule ThreadHost do
      use FullCircleWeb, :live_view

      def mount(_p, session, socket) do
        {:ok,
         assign(socket,
           current_company: FullCircle.Repo.get!(FullCircle.Sys.Company, session["company_id"]),
           current_user: FullCircle.Repo.get!(FullCircle.UserAccounts.User, session["user_id"]),
           record_id: session["record_id"]
         ), layout: false}
      end

      def render(assigns) do
        ~H"""
        <.live_component
          module={FullCircleWeb.NoteLive.NotesPanelComponent}
          id="thread"
          layout={:thread}
          record_type="Note"
          record_id={@record_id}
          current_company={@current_company}
          current_user={@current_user}
        />
        """
      end
    end

    test "thread layout: reply box always open, reply is about the note", %{
      conn: conn,
      admin: admin,
      comp: comp
    } do
      parent = note_fixture(comp, admin, %{"body" => "Genset broke down"})

      {:ok, lv, html} =
        live_isolated(conn, ThreadHost,
          session: %{"company_id" => comp.id, "user_id" => admin.id, "record_id" => parent.id}
        )

      assert html =~ "Post your reply…"
      refute has_element?(lv, "#thread-new")

      lv |> form("#thread-form", %{"note" => %{"body" => "Technician Monday"}}) |> render_submit()
      assert render(lv) =~ "Technician Monday"

      reply = FullCircle.Repo.get_by!(FullCircle.Notes.Note, body: "Technician Monday")
      assert {reply.subject_type, reply.subject_id} == {"Note", parent.id}
    end

    test "card layout: Cancel closes the quick-add", %{conn: conn, comp: comp, contact: c} do
      {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/contacts/#{c.id}/edit")
      lv |> element("#notes-panel-new") |> render_click()
      assert has_element?(lv, "#notes-panel-form")
      lv |> element("#notes-panel-cancel") |> render_click()
      refute has_element?(lv, "#notes-panel-form")
    end
  end
```

- [ ] **Step 2: Run to verify failure**

Run: `mix test test/full_circle_web/live/notes_panel_live_test.exs`
Expected: FAIL — no `layout` attr / no `#thread-form` / no `#notes-panel-cancel`.

- [ ] **Step 3: Rewrite the panel's quick-add**

In `lib/full_circle_web/live/note_live/notes_panel_component.ex`:
1. Add a first `update/2` clause for composer events:

```elixir
  # The quick-add composer saved (or was cancelled).
  @impl true
  def update(%{composer: {_cid, event}}, socket) do
    %{record_type: t, record_id: id} = socket.assigns

    case event do
      {:saved, _mode, _note} ->
        if socket.assigns.notify_parent, do: send(self(), {:notes_changed, t, id})
        {:ok, socket |> assign(adding: false) |> load()}

      :cancelled ->
        {:ok, assign(socket, adding: false)}
    end
  end
```

2. In the existing `update/2`, add `|> assign_new(:layout, fn -> :card end)`; remove the `form:` / `params` assigns and the `panel_form/2`, `panel_change/2`, `blank_note/1` helpers, and the `"validate"`, `"visibility_everyone"`, `"visibility_private"`, `"save"` event handlers (the composer owns them). Keep `"new"`, `"cancel"`, `"attachment_uploaded"`.
3. In `render/1`, replace the `<.form :if={@adding} …> … </.form>` block with:

```heex
      <div
        :if={@adding or @layout == :thread}
        class="border-b border-gray-200 px-4 py-3 dark:border-gray-700"
      >
        <.live_component
          module={FullCircleWeb.NoteLive.ComposerComponent}
          id={@id}
          notify={{__MODULE__, @id}}
          fixed_subject={{@record_type, @record_id}}
          roles_open={@layout == :card}
          roles={@record_type != "Task"}
          default_visibility={if @record_type == "Task", do: Note.private_visibility()}
          private_title={
            if @record_type == "Task",
              do: gettext("Only the people who can see this task (and admins) can read it.")
          }
          hint={
            if @record_type == "Task",
              do: gettext("Everyone who can see this task can read its notes.")
          }
          avatar={@layout == :thread}
          cancellable={@layout == :card}
          placeholder={if @layout == :thread, do: gettext("Post your reply…")}
          submit_label={if @layout == :thread, do: gettext("Reply"), else: gettext("Post")}
          current_company={@current_company}
          current_user={@current_user}
        />
      </div>
```

   The composer gets the panel's own `id` (allowed: LiveComponent ids are unique per module), so its form is `"#{@id}-form"` and its chips `"#{@id}-visibility-…"` exactly as before; its root element is `"#{@id}-box"`, so it never collides with the panel's `<section id={@id}>`.
4. Wrap the header and the card frame in `:if={@layout == :card}`-dependent classes: for `:thread` render the section without `rounded-xl border max-w-2xl mx-auto mt-3` and without the header row (count, Full form, + Note).
5. Keep `alias FullCircle.Notes.Note` (used for `private_visibility/0`).

- [ ] **Step 4: Run the tests**

Run: `mix test test/full_circle_web/live/notes_panel_live_test.exs test/full_circle_web/live/task_live_test.exs test/full_circle_web/live/note_live_test.exs`
Expected: PASS (existing quick-add tests: `#notes-panel-new` → `#notes-panel-form` submit; task panel `#task-notes-visibility-private[data-selected]`; modal `#notes-modal-panel-new/-form`).

- [ ] **Step 5: Commit**

```bash
mix format lib/full_circle_web/live/note_live/notes_panel_component.ex test/full_circle_web/live/notes_panel_live_test.exs
git add lib/full_circle_web/live/note_live/notes_panel_component.ex test/full_circle_web/live/notes_panel_live_test.exs test/full_circle_web/live/task_live_test.exs
git commit -m "refactor(notes): panel quick-add is the composer; thread layout for the note page

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: `note_post` detail variant; note links go to the post view

**Files:**
- Modify: `lib/full_circle_web/components/note_components.ex` (`note_post/1`)
- Modify: `lib/full_circle/linkable.ex` (`url/3`)
- Modify: `lib/full_circle_web/router.ex` (`/notes/:note_id` → `:show`)
- Modify: `lib/full_circle_web/live/note_live/form.ex` (temporarily treat `:show` like `:edit` so routes keep working until Task 6)
- Test: `test/full_circle/linkable_test.exs`, `test/full_circle_web/live/note_live_test.exs`

**Interfaces:**
- Produces: `note_post/1` attrs `detail` (boolean, default false) and slot `:actions`. With `detail`: body `text-lg`, no `line-clamp`, body not wrapped in a link, every attachment in the grid (no "+n more"), full timestamp (`Helpers.format_datetime/2`), counts row not wrapped in a link, `render_slot(@actions)` at the end of the counts row, root element id = `@id`. Without `detail`: unchanged.
- `Linkable.url("Note", id, company)` = `"/companies/#{company.id}/notes/#{id}"`; feed/panel post links → same.
- Router: `live("/notes/:note_id", NoteLive.Form, :show)`.

- [ ] **Step 1: Write the failing tests**

In `test/full_circle/linkable_test.exs` add:

```elixir
  test "a note's url is its post page", %{admin: admin, company: company} do
    note = note_fixture(company, admin, %{"body" => "x"})
    assert Linkable.url("Note", note.id, company) == "/companies/#{company.id}/notes/#{note.id}"
  end
```

In `test/full_circle_web/live/note_live_test.exs`, test "feed chips open records in a new tab; the post opens in the same tab": change the `refute` href to `"/companies/#{comp.id}/notes/#{note.id}"` and add after it:

```elixir
      assert has_element?(lv, ~s(#notes-#{note.id} a[href="/companies/#{comp.id}/notes/#{note.id}"]))
```

- [ ] **Step 2: Run to verify failure**

Run: `mix test test/full_circle/linkable_test.exs test/full_circle_web/live/note_live_test.exs`
Expected: FAIL — URLs still end in `/edit`.

- [ ] **Step 3: Implement**

1. `lib/full_circle/linkable.ex` `url/3`: `:note -> "/companies/#{company.id}/notes/#{id}"`.
2. `router.ex`: change `live("/notes/:note_id", NoteLive.Form, :edit)` to `live("/notes/:note_id", NoteLive.Form, :show)` (keep its comment: "The post page; /edit opens it in edit mode.").
3. `note_live/form.ex` `mount/3`: change `:edit ->` to `action when action in [:edit, :show] ->` (Task 6 rewrites this page; this keeps it working).
4. `note_components.ex` `note_post/1`:
   - add `attr :detail, :boolean, default: false` and `slot :actions`;
   - `path:` → `"/companies/#{assigns.current_company.id}/notes/#{note.id}"`;
   - `shown = if assigns.detail, do: note.attachments, else: Enum.take(note.attachments, 4)`;
   - timestamp span: `{if @detail, do: FullCircleWeb.Helpers.format_datetime(@note.inserted_at, @current_company), else: "· " <> ago(@note.inserted_at, @current_company)}` (keep the `title` tooltip);
   - body: when `@detail`, render without `post_link` —

```heex
        <div :if={@detail} class="mt-2">
          <div :if={@note.title} class="note-title text-xl font-bold">{@note.title}</div>
          <div phx-no-format class="whitespace-pre-wrap break-words text-lg">{@note.body}</div>
        </div>
        <.post_link :if={!@detail} path={@path} new_tab={@new_tab} class="mt-1 block">
          <div :if={@note.title} class="note-title font-bold">{@note.title}</div>
          <div phx-no-format class="line-clamp-8 whitespace-pre-wrap break-words">{@note.body}</div>
        </.post_link>
```

   - counts row: when `@detail`, render the three counts as plain spans (same classes `note-replies` / `note-links` / `note-files`) instead of inside `post_link`, then `{render_slot(@actions)}` with `class="ml-auto flex items-center gap-3"` wrapper; when not detail, unchanged.
   - the grid's `h-32`/`h-56` sizing stays; with `detail` and more than 4 files the grid simply grows.

- [ ] **Step 4: Run the tests**

Run: `mix test test/full_circle/linkable_test.exs test/full_circle_web/live/note_live_test.exs test/full_circle_web/live/notes_panel_live_test.exs test/full_circle_web/live/command_palette_notes_test.exs`
Expected: PASS. If a palette or panel test asserted a `/notes/:id/edit` href, update it to `/notes/:id` (that is the new contract).

- [ ] **Step 5: Commit**

```bash
mix format lib/full_circle_web/components/note_components.ex lib/full_circle/linkable.ex lib/full_circle_web/router.ex lib/full_circle_web/live/note_live/form.ex test/full_circle/linkable_test.exs test/full_circle_web/live/note_live_test.exs
git add -u
git commit -m "feat(notes): note_post detail variant; note links open the post page

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: The note page — post view, inline edit, thread

**Files:**
- Rewrite: `lib/full_circle_web/live/note_live/form.ex`
- Test: `test/full_circle_web/live/note_live_test.exs` (describe "note page" updated + new tests)

**Interfaces:**
- Consumes: composer (`id="note"`, `mode :new | :edit`, `full`, `cancellable` in edit, `initial_subject` on new, notify `:liveview`), `note_post detail`, `NotesPanelComponent layout={:thread}` with `id="notes-panel"`, `attach_button/1`, `attachment_tiles/1`.
- Produces DOM ids: `#note-post` (post view), `#edit-note`, `#delete-note` (in the `⋯` menu, both modes), `#toggle-history`, `#note-history`, `#note-files` (edit-mode tiles), `#back-to-notes`.

- [ ] **Step 1: Update and add tests (new contract)**

In `test/full_circle_web/live/note_live_test.exs`, describe "note page":
- `pick/4` helper: `"#open-picker"` → `"#note-open-picker"`, `"#record-picker form"` → `"#note-picker form"`, `"#record-picker-pick-#{id}"` → `"#note-picker-pick-#{id}"`. Its comment becomes "The pick reaches the composer via send_update; read the page after it lands."
- `"#clear-subject"` → `"#note-clear-subject"`; `"#visibility-private"` → `"#note-visibility-private"`; `"#visibility-everyone"` → `"#note-visibility-everyone"`; the "clearing the subject" test's `element("#open-picker")` → `"#note-open-picker"` and its expected text "Set what this note is about" → "What is this note about?".
- "new note: first pick sets the subject…": after `render_submit()`, use `[note] = FullCircle.Repo.all(FullCircle.Notes.Note)` then `assert_redirect(lv, ~p"/companies/#{comp.id}/notes/#{note.id}")` instead of matching `{:error, {:live_redirect, …}}` on the submit result (the redirect now happens in `handle_info`).
- "creates a note about a contact with restricted visibility": unchanged except the redirect, if asserted.
- "saving an edit stays on the page and keeps a version": after `render_submit()`, assert `render(lv) =~ "Note saved."`, `has_element?(lv, "#note-post", "v2")`, `refute has_element?(lv, "#note-form")`.
- "a stale save keeps the typed text and warns": assert on `render(lv)` after submit.
- "shows files, links, notes linking here and history" (opens `/edit` = edit mode): unchanged assertions; `#att-#{att.id} button` is in `#note-files`.
- "a note can be written about this note from its page": drop the `#notes-panel-new` click; submit `#notes-panel-form`; assert on `render(lv)`.
- "someone who can read but not edit gets the page read-only": replace the textarea/Save assertions with `assert has_element?(lv, "#note-post", "admin wrote this")`, `refute has_element?(lv, "#note-form")`, `refute has_element?(lv, "#edit-note")`, `refute has_element?(lv, "#delete-note")`.
- "the old /notes/:id address opens the same page" → rename "the /notes/:id address opens the post view": `assert has_element?(lv, "#note-post")`, `refute has_element?(lv, "#note-form")`.

Add these tests:

```elixir
    test "Edit turns the post into the write box; Cancel brings the post back",
         %{conn: conn, admin: admin, comp: comp} do
      note = note_fixture(comp, admin, %{"body" => "Any note"})
      {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/notes/#{note.id}")
      assert has_element?(lv, "#note-post", "Any note")

      lv |> element("#edit-note") |> render_click()
      assert has_element?(lv, "#note-form textarea", "Any note")
      refute has_element?(lv, "#note-post")

      lv |> element("#note-cancel") |> render_click()
      assert has_element?(lv, "#note-post", "Any note")
    end

    test "a reader opening /edit gets the post view", %{admin: admin, comp: comp} do
      note = note_fixture(comp, admin, %{"body" => "read me"})
      clerk = user_with_role(comp, admin, "clerk")
      {:ok, lv, _} = live(log_in_user(build_conn(), clerk), edit_path(comp, note))
      assert has_element?(lv, "#note-post", "read me")
      refute has_element?(lv, "#note-form")
      refute has_element?(lv, "#delete-note")
    end

    test "pick goes to the edit box only, not the reply box",
         %{conn: conn, admin: admin, comp: comp} do
      mei = contact_fixture(comp, admin, %{"name" => "Kedai Mei"})
      note = note_fixture(comp, admin, %{"body" => "b"})
      {:ok, lv, _} = live(conn, edit_path(comp, note))
      pick(lv, "Contact", "Mei", mei.id)
      assert has_element?(lv, "#note-form", "Kedai Mei")
      refute has_element?(lv, "#notes-panel-form", "Kedai Mei")
    end

    test "attachment_uploaded refreshes tiles in edit mode", %{conn: conn, admin: admin, comp: comp} do
      note = note_fixture(comp, admin, %{"body" => "files"})
      {:ok, lv, _} = live(conn, edit_path(comp, note))
      refute has_element?(lv, "#note-files", "late.jpg")

      {:ok, _} =
        FullCircle.Notes.Attachments.attach(note, %{path: jpeg_file(), file_name: "late.jpg"}, comp, admin)

      render_hook(lv, "attachment_uploaded", %{})
      assert has_element?(lv, "#note-files", "late.jpg")
    end

    test "the post view shows every file, the full body and a History toggle",
         %{conn: conn, admin: admin, comp: comp} do
      note = note_fixture(comp, admin, %{"body" => "v1"})
      {:ok, note} = FullCircle.Notes.update_note(note, %{"body" => "v2"}, comp, admin)

      for n <- 1..5 do
        {:ok, _} =
          FullCircle.Notes.Attachments.attach(note, %{path: jpeg_file(), file_name: "#{n}.jpg"}, comp, admin)
      end

      {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/notes/#{note.id}")
      assert lv |> element("#note-post") |> render() |> LazyHTML.from_fragment() |> LazyHTML.query(".note-thumb") |> Enum.count() == 5
      html = lv |> element("#toggle-history") |> render_click()
      assert html =~ "v1"
    end
```

- [ ] **Step 2: Run to verify failure**

Run: `mix test test/full_circle_web/live/note_live_test.exs`
Expected: FAIL — no `#note-post`, `#edit-note`, `#note-open-picker`, etc.

- [ ] **Step 3: Rewrite `lib/full_circle_web/live/note_live/form.ex`**

```elixir
defmodule FullCircleWeb.NoteLive.Form do
  @moduledoc """
  The note's page, shaped like the feed (an x.com single-post page): the note
  as a large post, ✎ Edit turning it into the shared write box in place, files
  and history inside the post, and the replies thread below. /notes/new is the
  write box full size. /notes/:id opens the post; /notes/:id/edit opens it in
  edit mode when the user may edit. Contract: `.claude/skills/notes.md`.
  """
  use FullCircleWeb, :live_view

  import FullCircleWeb.NoteComponents

  alias FullCircle.{Linkable, Notes, Repo}
  alias FullCircle.Notes.{Attachments, Note}
  alias FullCircleWeb.NoteLive.{ComposerComponent, NotesPanelComponent}

  @impl true
  def mount(params, _session, socket) do
    %{current_company: com, current_user: user} = socket.assigns
    socket = assign(socket, show_history: false, history: [])

    case socket.assigns.live_action do
      :new ->
        if FullCircle.Authorization.can?(user, :create_note, com),
          do: {:ok, mount_new(socket, params)},
          else: {:ok, deny(socket, gettext("You cannot create notes."))}

      action ->
        case Notes.get_note(params["note_id"], com, user) do
          %Note{} = note ->
            socket = assign_note(socket, note)
            {:ok, assign(socket, editing: action == :edit and socket.assigns.can_edit)}

          nil ->
            {:ok, deny(socket, gettext("Note not found."))}
        end
    end
  end

  defp deny(socket, msg) do
    socket
    |> put_flash(:warn, msg)
    |> push_navigate(to: ~p"/companies/#{socket.assigns.current_company.id}/notes")
  end

  defp mount_new(socket, params) do
    subject =
      with t when is_binary(t) <- params["subject_type"],
           {:ok, target} <-
             Linkable.resolve(t, params["subject_id"], socket.assigns.current_company, socket.assigns.current_user) do
        %{type: t, id: target.id, title: target.title}
      else
        _ -> nil
      end

    assign(socket, page_title: gettext("New Note"), note: nil, subject: subject, editing: false)
  end

  # Everything shown for a saved note: rights, the post item, files, history.
  defp assign_note(socket, note) do
    %{current_company: com, current_user: user} = socket.assigns
    note = Repo.preload(note, [:author, :updated_by, :attachments], force: true)

    socket
    |> assign(
      page_title: gettext("Note"),
      note: note,
      can_edit: Notes.can_edit?(note, com, user),
      can_delete: Notes.can_delete?(note, com, user),
      item: %{id: note.id, note: note, d: Map.fetch!(Notes.feed_details([note], com, user), note.id)}
    )
    |> assign_history()
  end

  defp reload(socket) do
    %{note: note, current_company: com, current_user: user} = socket.assigns

    case Notes.get_note(note.id, com, user) do
      nil -> deny(socket, gettext("Note not found."))
      fresh -> assign_note(socket, fresh)
    end
  end

  defp assign_history(%{assigns: %{show_history: false}} = socket), do: assign(socket, history: [])

  defp assign_history(socket) do
    %{note: note, current_company: com, current_user: user} = socket.assigns
    assign(socket, history: Notes.version_changes(Notes.list_versions(note, com, user), note))
  end

  @impl true
  def handle_event("edit", _, socket),
    do: {:noreply, assign(socket, editing: socket.assigns.can_edit)}

  def handle_event("toggle_history", _, socket),
    do: {:noreply, socket |> assign(show_history: !socket.assigns.show_history) |> assign_history()}

  def handle_event("attachment_uploaded", _, socket), do: {:noreply, reload(socket)}

  def handle_event("remove_attachment", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.note.attachments, &(&1.id == id)) do
      nil ->
        {:noreply, socket}

      att ->
        Attachments.remove(att, socket.assigns.current_company, socket.assigns.current_user)
        {:noreply, reload(socket)}
    end
  end

  def handle_event("delete", _, socket) do
    %{note: note, current_company: com, current_user: user} = socket.assigns

    case Notes.delete_note(note, com, user) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Note deleted."))
         |> push_navigate(to: ~p"/companies/#{com.id}/notes")}

      _ ->
        {:noreply, put_flash(socket, :warn, gettext("Not Authorise."))}
    end
  end

  @impl true
  def handle_info({:composer, "note", {:saved, :new, note}}, socket) do
    {:noreply,
     socket
     |> put_flash(:info, gettext("Note saved."))
     |> push_navigate(to: ~p"/companies/#{socket.assigns.current_company.id}/notes/#{note.id}")}
  end

  def handle_info({:composer, "note", {:saved, :edit, _note}}, socket) do
    {:noreply, socket |> assign(editing: false) |> reload() |> put_flash(:info, gettext("Note saved."))}
  end

  # Links on a saved note apply immediately, so a cancelled edit still reloads.
  def handle_info({:composer, "note", :cancelled}, socket),
    do: {:noreply, socket |> assign(editing: false) |> reload()}

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp show_value(nil), do: "—"
  defp show_value(list) when is_list(list), do: Enum.join(list, ", ")
  defp show_value(v), do: to_string(v)

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-xl border-x border-gray-200 bg-white dark:border-gray-700 dark:bg-gray-900">
      <div class="flex items-center gap-4 border-b border-gray-200 px-4 py-2 dark:border-gray-700">
        <.link
          id="back-to-notes"
          navigate={~p"/companies/#{@current_company.id}/notes"}
          class="rounded-full px-2 text-xl hover:bg-gray-100 dark:hover:bg-gray-800"
          title={gettext("Back")}
        >
          ←
        </.link>
        <span class="text-lg font-bold">{@page_title}</span>
        <details :if={@note && @can_delete} class="relative ml-auto">
          <summary class="cursor-pointer list-none rounded-full px-2 text-xl hover:bg-gray-100 dark:hover:bg-gray-800">
            ⋯
          </summary>
          <div class="absolute right-0 z-10 mt-1 w-40 rounded-lg border border-gray-200 bg-white py-1 shadow-lg dark:border-gray-700 dark:bg-gray-800">
            <button
              type="button"
              id="delete-note"
              phx-click="delete"
              data-confirm={gettext("Delete this note? Its history is kept.")}
              class="block w-full px-3 py-1.5 text-left text-sm text-rose-700 hover:bg-rose-50 dark:text-rose-300 dark:hover:bg-rose-950"
            >
              {gettext("Delete")}
            </button>
          </div>
        </details>
      </div>

      <div :if={is_nil(@note)} class="px-4 py-3">
        <.live_component
          module={ComposerComponent}
          id="note"
          full
          avatar
          initial_subject={@subject}
          current_company={@current_company}
          current_user={@current_user}
        />
        <p class="mt-2 text-xs text-gray-500">{gettext("Save the note first, then attach files.")}</p>
      </div>

      <%= if @note do %>
        <.note_post
          :if={!@editing}
          id="note-post"
          item={@item}
          current_company={@current_company}
          detail
        >
          <:actions>
            <button
              :if={@can_edit}
              type="button"
              id="edit-note"
              phx-click="edit"
              class="rounded-full border border-gray-300 px-3 py-0.5 text-sm hover:bg-gray-100 dark:border-gray-600 dark:hover:bg-gray-800"
            >
              ✎ {gettext("Edit")}
            </button>
            <.attach_button :if={@can_edit} note_id={@note.id} current_company={@current_company} />
            <button
              type="button"
              id="toggle-history"
              phx-click="toggle_history"
              class="text-xs text-gray-500 hover:underline"
            >
              {gettext("History")} {if @show_history, do: "▾", else: "▸"}
            </button>
          </:actions>
        </.note_post>

        <div :if={@editing} class="border-b border-gray-200 px-4 py-3 dark:border-gray-700">
          <.live_component
            module={ComposerComponent}
            id="note"
            mode={:edit}
            note={@note}
            full
            avatar
            cancellable
            submit_label={gettext("Save")}
            current_company={@current_company}
            current_user={@current_user}
          />
          <div id="note-files" class="mt-3">
            <div class="mb-2 flex items-center">
              <span class="text-sm font-semibold">📎 {gettext("Files")}</span>
              <span class="ml-auto">
                <.attach_button note_id={@note.id} current_company={@current_company} />
              </span>
            </div>
            <.attachment_tiles attachments={@note.attachments} current_company={@current_company} can_edit />
          </div>
          <button
            type="button"
            id="toggle-history"
            phx-click="toggle_history"
            class="mt-2 text-xs text-gray-500 hover:underline"
          >
            {gettext("History")} {if @show_history, do: "▾", else: "▸"}
          </button>
        </div>

        <div
          :if={@show_history}
          id="note-history"
          class="border-b border-gray-200 px-4 py-2 text-sm dark:border-gray-700"
        >
          <div :for={h <- @history} class="my-1 rounded border border-gray-200 p-2 dark:border-gray-700">
            <div class="text-xs text-gray-500">
              {gettext("Version")} {h.version.version} · {gettext("replaced by")} {h.version.edited_by.email}
              {FullCircleWeb.Helpers.format_datetime(h.version.inserted_at, @current_company)}
            </div>
            <div :for={{field, old, new} <- h.changes}>
              <span class="font-semibold">{field}</span>: <span
                phx-no-format
                class="whitespace-pre-wrap bg-rose-100 line-through dark:bg-rose-900"
              >{show_value(old)}</span> →
              <span class="whitespace-pre-wrap bg-green-100 dark:bg-green-900">{show_value(new)}</span>
            </div>
          </div>
          <p :if={@history == []} class="text-gray-500">{gettext("Never edited.")}</p>
        </div>

        <.live_component
          module={NotesPanelComponent}
          id="notes-panel"
          layout={:thread}
          record_type="Note"
          record_id={@note.id}
          current_company={@current_company}
          current_user={@current_user}
        />
      <% end %>
    </div>
    """
  end
end
```

Notes for the implementer:
- `attach_button/1`'s hook pushes `"attachment_uploaded"` to the element's owner; both buttons sit in this LiveView (not a component), so `handle_event("attachment_uploaded", …)` here receives it. Two attach buttons never render at once (`:if={!@editing}` vs `:if={@editing}`), so their ids don't collide; check `attach_button`'s id scheme with `grep -n "def attach_button" -A20 lib/full_circle_web/components/note_components.ex`.
- `#toggle-history` appears in both modes but never at once.
- If `note_post`'s `actions` slot renders inside a `post_link` anchor for non-detail posts, that is fine — the slot is only used here with `detail`.

- [ ] **Step 4: Run the tests**

Run: `mix test test/full_circle_web/live/note_live_test.exs test/full_circle_web/live/notes_panel_live_test.exs test/full_circle_web/live/note_composer_test.exs test/full_circle_web/controllers`
Expected: PASS. Then `mix compile --force` (no warnings) and `mix test` (full suite) once.

- [ ] **Step 5: Commit**

```bash
mix format lib/full_circle_web/live/note_live/form.ex test/full_circle_web/live/note_live_test.exs
git add lib/full_circle_web/live/note_live/form.ex test/full_circle_web/live/note_live_test.exs
git commit -m "feat(notes): note page as a post with inline edit and a reply thread

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: Translations and the notes skill

**Files:**
- Modify: `priv/gettext/zh/LC_MESSAGES/default.po`, `.claude/skills/notes.md`

- [ ] **Step 1: New strings**

Run: `grep -rhoE 'gettext\("[^"]+"' lib/full_circle_web/live/note_live/composer_component.ex lib/full_circle_web/live/note_live/form.ex lib/full_circle_web/live/note_live/notes_panel_component.ex | sort -u`, and for each check `grep -c '^msgid "<text>"$' priv/gettext/zh/LC_MESSAGES/default.po`. Append only the missing ones, e.g.:

```po
msgid "Post your reply…"
msgstr "发表回复…"

msgid "Reply"
msgstr "回复"

msgid "Title (optional)"
msgstr "标题（可选）"

msgid "Edit"
msgstr "编辑"

msgid "History"
msgstr "历史"

msgid "What is this note about?"
msgstr "这条备注是关于什么的？"

msgid "Link other records"
msgstr "关联其他记录"
```

Run `mix compile` — no gettext errors.

- [ ] **Step 2: Update `.claude/skills/notes.md`**

- Replace "## Note page" with: the page is an x.com single-post page in the feed's column (`NoteLive.Form`): `/notes/:id` (`:show`) post view via `note_post detail`; `/notes/:id/edit` opens edit mode only when `can_edit?`; ✎ Edit swaps the post for the composer in place; Delete lives in the `⋯` menu (`#delete-note`); files: grid in the post, tiles + remove in edit mode (`#note-files`); History toggle (`#toggle-history`, per-version filtered); replies: `NotesPanelComponent layout={:thread}`; `/notes/new` is the composer full size.
- Add "## One write box: `ComposerComponent`": attrs table from the plan's Task 1 Interfaces; DOM id scheme; `notify` (`:liveview` → `{:composer, id, event}`, `{mod, id}` → `send_update(..., composer: {id, event})`); picks reach it via `RecordPickerComponent notify` (`send_update(..., picked: {picker_id, picked})`); state survives host re-renders (reset only after save/cancel); hosts: feed `compose`, note page `note`, panels use their own id.
- In "Two note forms on one page": the composer's id prefix is what keeps ids unique now (replaces the `compose_note` / `#{id}_note` notes).
- In "Navigation between notes and records": note links go to `/notes/:id`.

- [ ] **Step 3: Full suite and commit**

Run: `mix test` — Expected: 0 failures.

```bash
git add priv/gettext/zh/LC_MESSAGES/default.po .claude/skills/notes.md
git commit -m "docs(notes): composer and note page contracts; zh strings

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

## Controller: browser pass (after Task 7)

In light and dark theme: feed post box (post, about…, Everyone ▾), note page post view (long body, files, counts, Edit, ⋯ Delete, History), inline edit (title, chips, links, Save, Cancel, stale warning), reply thread (Post your reply…, reply appears), new note page, a record panel (Contact) quick-add and the task panel (Private, no role chips).
