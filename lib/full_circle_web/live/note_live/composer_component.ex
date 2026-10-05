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
  alias FullCircle.Notes.{Note, Trays}
  alias FullCircleWeb.NoteLive.{PhoneQrComponent, RecordPickerComponent}

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
    notify: :liveview,
    reply_to: nil,
    layout: :box,
    header: [],
    files: [],
    footer: [],
    actions: []
  ]

  # A pick from this box's picker (RecordPickerComponent notify).
  @impl true
  def update(%{picked: {_picker_id, picked}}, socket), do: {:ok, pick(socket, picked)}

  # A file landed in this box's tray (FullCircleWeb.NoteFiles): desktop 📎,
  # drop, paste, or the phone.
  def update(%{note_files: {:tray, _}}, socket), do: {:ok, load_tray(socket)}

  def update(assigns, socket) do
    first? = is_nil(socket.assigns[:rev])

    # A host handing over another note, or a newer save of it, starts the box
    # afresh. LiveView keeps a removed component's state when it is rendered
    # again before the client confirms the removal (the note page: Save, then
    # Edit straight away), so first? alone would show the pre-save text and
    # lock_version. Hosts pass the same note on ordinary re-renders, which
    # keeps half-typed text.
    renote? =
      not first? and Map.has_key?(assigns, :note) and
        note_key(assigns.note) != note_key(socket.assigns[:note])

    socket =
      Enum.reduce(@defaults, assign(socket, assigns), fn {k, v}, s ->
        assign_new(s, k, fn -> v end)
      end)

    {:ok, if(first? or renote?, do: reset(socket), else: socket)}
  end

  defp note_key(%Note{id: id, lock_version: v}), do: {id, v}
  defp note_key(_), do: nil

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
      # A box that starts with the chips folded keeps its pill as the toggle.
      compact: not roles_open?(socket.assigns),
      subject: initial_subject(socket),
      links: initial_links(socket)
    )
    |> assign(
      form: to_form(Notes.change_note(base_note(socket.assigns)), id: "#{socket.assigns.id}_note")
    )
    |> new_tray()
  end

  # Each fresh box (open, after Save, after Cancel) gets a new tray id. The
  # row is created on first upload or when the phone QR opens.
  defp new_tray(socket) do
    tray_id = Ecto.UUID.generate()
    FullCircleWeb.NoteFiles.listen({:tray, tray_id}, __MODULE__, socket.assigns.id)
    assign(socket, tray_id: tray_id, tray_files: [])
  end

  defp load_tray(socket) do
    %{tray_id: id, current_company: com, current_user: user} = socket.assigns
    assign(socket, tray_files: Trays.list(id, com, user))
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

  # A reply takes its root's subject (Notes enforces it): send none.
  defp subject_attrs(%{reply_to: %Note{}}), do: %{}

  defp subject_attrs(%{mode: :edit, note: %Note{reply_to_id: id}}) when not is_nil(id),
    do: %{}

  defp subject_attrs(%{fixed_subject: {t, id}}), do: %{"subject_type" => t, "subject_id" => id}

  defp subject_attrs(%{subject: %{type: t, id: id}}),
    do: %{"subject_type" => t, "subject_id" => id}

  defp subject_attrs(_), do: %{"subject_type" => nil, "subject_id" => nil}

  defp change(socket, params) do
    cs =
      socket.assigns
      |> base_note()
      |> Notes.change_note(Map.merge(params, subject_attrs(socket.assigns)),
        files?: has_files?(socket.assigns)
      )
      |> Map.put(:action, :validate)

    assign(socket, form: to_form(cs, id: "#{socket.assigns.id}_note"), params: params)
  end

  # Files in the box (or already on the note being edited) make text optional.
  defp has_files?(%{tray_files: [_ | _]}), do: true
  defp has_files?(%{mode: :edit, note: %Note{attachments: [_ | _]}}), do: true
  defp has_files?(_assigns), do: false

  defp notify(%{assigns: %{notify: :liveview, id: id}}, event),
    do: send(self(), {:composer, id, event})

  defp notify(%{assigns: %{notify: {module, cid}, id: id}}, event),
    do: send_update(module, id: cid, composer: {id, event})

  # --- events ---------------------------------------------------------------

  @impl true
  # A message about the last action (a link, a stale save) goes once the
  # user edits again.
  def handle_event("validate", %{"note" => params}, socket),
    do: {:noreply, socket |> change(params) |> assign(error: nil)}

  def handle_event("visibility_everyone", _, socket),
    do: {:noreply, change(socket, Map.put(socket.assigns.params, "visibility", [""]))}

  def handle_event("visibility_private", _, socket),
    do:
      {:noreply,
       change(socket, Map.put(socket.assigns.params, "visibility", Note.private_visibility()))}

  def handle_event("toggle_roles", _, socket),
    do: {:noreply, assign(socket, show_roles: !socket.assigns.show_roles)}

  def handle_event("toggle_picker", _, socket),
    do: {:noreply, assign(socket, picker_open: !socket.assigns.picker_open)}

  def handle_event("clear_subject", _, socket), do: {:noreply, assign(socket, subject: nil)}

  def handle_event("remove_queued_link", %{"id" => id}, socket),
    do: {:noreply, assign(socket, links: Enum.reject(socket.assigns.links, &(&1.id == id)))}

  def handle_event("remove_link", %{"id" => link_id}, socket) do
    %{note: note, current_company: com, current_user: user} = socket.assigns

    # A malformed id from the client must not reach the binary_id query.
    case Ecto.UUID.cast(link_id) do
      {:ok, uuid} ->
        Notes.remove_link(note, uuid, com, user)
        {:noreply, assign(socket, links: Notes.list_links(note, com, user))}

      :error ->
        {:noreply, socket}
    end
  end

  # The box's own 📎 / drop / paste finished an upload (the broadcast also
  # arrives; loading twice is harmless).
  def handle_event("attachment_uploaded", _, socket), do: {:noreply, load_tray(socket)}

  def handle_event("discard_file", %{"id" => id}, socket) do
    %{tray_id: tray_id, current_company: com, current_user: user} = socket.assigns
    Trays.discard_file(id, tray_id, com, user)
    {:noreply, load_tray(socket)}
  end

  def handle_event("cancel", _, socket) do
    %{tray_id: tray_id, current_company: com, current_user: user} = socket.assigns
    Trays.cancel(tray_id, com, user)
    notify(socket, :cancelled)
    {:noreply, reset(socket)}
  end

  def handle_event("save", %{"note" => params}, socket) do
    %{current_company: com, current_user: user, mode: mode} = socket.assigns

    params =
      params
      |> Map.merge(subject_attrs(socket.assigns))
      |> Map.put("tray_id", socket.assigns.tray_id)

    result =
      case mode do
        :edit ->
          Notes.update_note(socket.assigns.note, params, com, user)

        _ ->
          links = Enum.map(socket.assigns.links, &%{"type" => &1.type, "id" => &1.id})

          params =
            case socket.assigns.reply_to do
              %Note{id: id} -> Map.put(params, "reply_to_id", id)
              nil -> params
            end

          Notes.create_note(Map.put(params, "links", links), com, user)
      end

    case result do
      {:ok, note} ->
        notify(socket, {:saved, mode, note})
        {:noreply, reset(socket)}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply,
         assign(socket, form: to_form(cs, id: "#{socket.assigns.id}_note"), params: params)}

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
      # A fixed subject (a record's notes panel) is set: every pick is a link.
      fixed_subject?(socket.assigns, picked) ->
        socket

      socket.assigns.fixed_subject && mode != :edit ->
        assign(socket, links: Enum.uniq_by(socket.assigns.links ++ [picked], &{&1.type, &1.id}))

      # A reply's subject is its root's: every pick is a link.
      replying?(socket.assigns) and mode == :edit ->
        add_saved_link(socket, picked)

      replying?(socket.assigns) ->
        assign(socket, links: Enum.uniq_by(socket.assigns.links ++ [picked], &{&1.type, &1.id}))

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

  defp fixed_subject?(%{fixed_subject: {t, id}}, %{type: t, id: id}), do: true
  defp fixed_subject?(_assigns, _picked), do: false

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

  # A reply takes its root's subject and visibility (Notes enforces it); the
  # box offers neither, and every pick is a link.
  defp replying?(%{reply_to: %Note{}}), do: true
  defp replying?(%{mode: :edit, note: %Note{reply_to_id: id}}) when not is_nil(id), do: true
  defp replying?(_), do: false

  # --- render ---------------------------------------------------------------

  defp task_subject?(%{type: "Task"}, _fixed), do: true
  defp task_subject?(_subject, {"Task", _id}), do: true
  defp task_subject?(_subject, _fixed), do: false

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

  # By the chips and the picker: what went wrong with the record the note is
  # about, its links or who sees it. These come from the server, not from
  # typing, so they show at once.
  defp record_messages(assigns) do
    ~H"""
    <.field_errors
      id={"#{@id}-record-errors"}
      fields={
        for f <- [:subject_id, :subject_type, :visibility, :reply_to_id], do: {@form[f], nil, true}
      }
    />
    <p :if={@error} id={"#{@id}-error"} class="mt-0.5 text-xs text-rose-600 dark:text-rose-400">
      {@error}
    </p>
    """
  end

  # The edit box shows the note's author, like the post it replaces.
  defp author_email(%{mode: :edit, note: %Note{author: %{email: email}}}), do: email
  defp author_email(%{current_user: user}), do: user.email

  @impl true
  def render(%{layout: :post} = assigns) do
    assigns = assign(assigns, :replying, replying?(assigns))

    ~H"""
    <div id={"#{@id}-box"} class={["flex gap-3", @class]}>
      <.avatar email={author_email(assigns)} />
      <div class="min-w-0 flex-1">
        <%!-- The header hides its 🔒 tag only while the role chips below say it. --%>
        {render_slot(
          @header,
          @show_roles and not @replying and not task_subject?(@subject, @fixed_subject)
        )}
        <div class="mt-0.5 flex flex-wrap items-center gap-1">
          <.chips {chip_assigns(assigns)} />
        </div>
        <.picker :if={@picker_open} {picker_assigns(assigns)} class="mt-2" />
        <.record_messages {message_assigns(assigns)} />
        <.form
          for={@form}
          id={"#{@id}-form"}
          phx-change="validate"
          phx-submit="save"
          phx-target={@myself}
          autocomplete="off"
          class="mt-2"
        >
          <input
            type="text"
            id={"#{@id}_title"}
            name="note[title]"
            value={@form[:title].value}
            placeholder={gettext("Title (optional)")}
            class={[
              "w-full rounded-md border bg-transparent px-2 py-1 text-xl font-bold placeholder-gray-500",
              border(@form[:title], "border-gray-300 dark:border-gray-600")
            ]}
          />
          <.field_errors id={"#{@id}-title-errors"} fields={[{@form[:title], nil}]} />
          <textarea
            id={"#{@id}_body_#{@rev}"}
            name="note[body]"
            rows="6"
            placeholder={@placeholder || gettext("Write a note…")}
            class={[
              "mt-1 w-full resize-y rounded-md border bg-transparent px-2 py-1 text-lg placeholder-gray-500",
              border(@form[:body], "border-gray-300 dark:border-gray-600")
            ]}
          >{Phoenix.HTML.Form.normalize_value("textarea", @form[:body].value)}</textarea>
          <.messages {message_assigns(assigns)} />
          <.tray {tray_assigns(assigns)} />
          {render_slot(@files)}
          <.visibility_fields
            {visibility_assigns(assigns)}
            class="mt-2 flex flex-wrap items-center gap-1 text-xs"
          />
          <div class="mt-2 flex flex-wrap items-center gap-x-8 gap-y-2 text-sm text-gray-500 dark:text-gray-400">
            {render_slot(@footer)}
            <span class="ml-auto flex items-center gap-3">
              {render_slot(@actions)}
              <.submit_buttons {submit_assigns(assigns)} />
            </span>
          </div>
        </.form>
      </div>
    </div>
    """
  end

  def render(assigns) do
    assigns = assign(assigns, :replying, replying?(assigns))

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
          <.field_errors :if={@full} id={"#{@id}-title-errors"} fields={[{@form[:title], nil}]} />
          <textarea
            id={"#{@id}_body_#{@rev}"}
            name="note[body]"
            rows={if @full, do: 6, else: 2}
            placeholder={@placeholder || gettext("Write a note…")}
            class="w-full resize-y border-0 bg-transparent p-1 text-lg placeholder-gray-500 focus:ring-0"
          >{Phoenix.HTML.Form.normalize_value("textarea", @form[:body].value)}</textarea>
          <.messages {message_assigns(assigns)} />
          <.tray {tray_assigns(assigns)} />
          <.visibility_fields
            {visibility_assigns(assigns)}
            class="flex flex-wrap items-center gap-1 pb-2 text-xs"
          />
          <p
            :if={@hint && not @replying && not task_subject?(@subject, @fixed_subject)}
            class="pb-1 text-xs text-slate-500 dark:text-slate-400"
          >
            {@hint}
          </p>

          <div class="flex flex-wrap items-center gap-1 border-t border-gray-200 pt-2 dark:border-gray-700">
            <.chips {chip_assigns(assigns)} />
            <button
              :if={
                (@compact or !@show_roles) and not @replying and
                  not task_subject?(@subject, @fixed_subject)
              }
              id={"#{@id}-roles-toggle"}
              type="button"
              phx-click="toggle_roles"
              phx-target={@myself}
              class="rounded-full border border-gray-300 px-2 text-xs text-gray-600 dark:border-gray-600 dark:text-gray-300"
            >
              {visibility_label(roles_of(@form))} {if @show_roles, do: "▴", else: "▾"}
            </button>
            <span class="ml-auto flex items-center gap-2">
              <.link
                :if={@full_form_path}
                navigate={@full_form_path}
                class="text-xs text-gray-500 hover:underline"
              >
                {gettext("Full form")}
              </.link>
              <.submit_buttons {submit_assigns(assigns)} />
            </span>
          </div>
          <.record_messages {message_assigns(assigns)} />
        </.form>
        <.picker :if={@picker_open} {picker_assigns(assigns)} class="mt-2" />
      </div>
    </div>
    """
  end

  # The pieces both layouts share. Each gets only the assigns it reads.

  defp chip_assigns(a),
    do:
      Map.take(a, [
        :id,
        :myself,
        :subject,
        :fixed_subject,
        :replying,
        :links,
        :mode,
        :full,
        :layout,
        :current_company
      ])

  defp message_assigns(a), do: Map.take(a, [:id, :form, :error, :replying])

  defp visibility_assigns(a),
    do:
      Map.take(a, [
        :id,
        :myself,
        :form,
        :show_roles,
        :replying,
        :subject,
        :fixed_subject,
        :roles,
        :private_title
      ])

  defp submit_assigns(a), do: Map.take(a, [:id, :myself, :cancellable, :submit_label])

  defp picker_assigns(a),
    do: Map.take(a, [:id, :subject, :fixed_subject, :replying, :current_company, :current_user])

  defp chips(assigns) do
    ~H"""
    <%!-- A reply's subject is its root's: the post layout shows it, without ✕. --%>
    <.record_chip
      :if={@subject && !@fixed_subject && (!@replying or @layout == :post)}
      type={@subject.type}
      target={chip_target(@subject, @current_company)}
      kind={:subject}
    >
      <button
        :if={!@replying}
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
      :if={
        (!@fixed_subject or @full or @mode == :edit) and
          ((not @replying and (is_nil(@subject) or @full)) or (@replying and @full))
      }
      id={"#{@id}-open-picker"}
      type="button"
      phx-click="toggle_picker"
      phx-target={@myself}
      class={[
        "rounded-full border px-2 text-xs",
        if(is_nil(@subject) and not @replying and !@fixed_subject,
          do:
            "border-amber-400 bg-amber-50 text-amber-900 dark:border-amber-600 dark:bg-amber-950 dark:text-amber-100",
          else: "border-dashed border-gray-400 text-gray-600 dark:border-gray-500 dark:text-gray-300"
        )
      ]}
    >
      ＋ {if @subject || @replying || @fixed_subject,
        do: gettext("link a record"),
        else: gettext("about…")}
    </button>
    """
  end

  defp tray(assigns) do
    assigns =
      assign(
        assigns,
        :photo,
        FullCircle.Notes.Attachments.photo_settings(assigns.current_company)
      )

    ~H"""
    <div
      id={"#{@id}-tray"}
      data-tray-id={@tray_id}
      phx-hook="NoteDrop"
      data-url={~p"/companies/#{@current_company.id}/note_trays/#{@tray_id}/files"}
      data-max-bytes={FullCircle.Notes.Attachments.max_bytes()}
      data-max-edge={@photo.max_edge}
      data-quality={@photo.quality}
      class="mt-1"
    >
      <.file_grid
        id={"#{@id}-tray-files"}
        attachments={@tray_files}
        removable
        remove_event="discard_file"
        confirm={nil}
        target={@myself}
      />
      <div class="@container mt-1 flex flex-wrap items-center gap-2">
        <.attach_button
          id={"#{@id}-attach"}
          url={~p"/companies/#{@current_company.id}/note_trays/#{@tray_id}/files"}
          company={@current_company}
        />
        <.live_component
          module={PhoneQrComponent}
          id={"#{@id}-phone"}
          target={{:tray, @tray_id}}
          label={tray_label(assigns)}
          current_company={@current_company}
          current_user={@current_user}
        />
        <span class="text-xs text-gray-500 dark:text-gray-400">
          {gettext("or drop / paste files here")}
        </span>
      </div>
    </div>
    """
  end

  defp tray_label(%{mode: :edit, note: %Note{} = note}),
    do: FullCircleWeb.PhoneUpload.note_label(note)

  defp tray_label(_), do: gettext("a new note")

  defp tray_assigns(a),
    do:
      Map.take(a, [
        :id,
        :myself,
        :tray_id,
        :tray_files,
        :current_company,
        :current_user,
        :mode,
        :note
      ])

  # Under the body: its own errors. Nothing shows before the user has typed
  # in it or pressed Save (`show_errors?/1`).
  defp messages(assigns) do
    ~H"""
    <.field_errors id={"#{@id}-body-errors"} fields={[{@form[:body], nil}]} />
    <p
      :if={@replying}
      id={"#{@id}-reply-scope"}
      class="pb-1 text-xs text-slate-500 dark:text-slate-400"
    >
      {gettext("Visible to the same people as the note it replies to.")}
    </p>
    """
  end

  attr :class, :string, required: true

  defp visibility_fields(assigns) do
    ~H"""
    <div
      :if={@show_roles and not @replying and not task_subject?(@subject, @fixed_subject)}
      class={@class}
    >
      <.visibility_chips
        visibility={roles_of(@form)}
        id_prefix={"#{@id}-visibility"}
        target={@myself}
        roles={@roles}
        private_title={@private_title}
      />
    </div>
    <div :if={!@show_roles and not @replying and not task_subject?(@subject, @fixed_subject)}>
      <input type="hidden" name="note[visibility][]" value="" />
      <input :for={role <- roles_of(@form)} type="hidden" name="note[visibility][]" value={role} />
    </div>
    """
  end

  defp submit_buttons(assigns) do
    ~H"""
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
    """
  end

  attr :class, :string, default: nil

  defp picker(assigns) do
    ~H"""
    <div class={@class}>
      <.live_component
        module={RecordPickerComponent}
        id={"#{@id}-picker"}
        notify={{__MODULE__, @id}}
        label={
          if @subject || @replying || @fixed_subject,
            do: gettext("Link other records"),
            else: gettext("What is this note about?")
        }
        current_company={@current_company}
        current_user={@current_user}
      />
    </div>
    """
  end
end
