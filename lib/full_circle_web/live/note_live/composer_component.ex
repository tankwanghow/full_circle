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
    notify: :liveview,
    reply_to: nil
  ]

  # A pick from this box's picker (RecordPickerComponent notify).
  @impl true
  def update(%{picked: {_picker_id, picked}}, socket), do: {:ok, pick(socket, picked)}

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
      |> Notes.change_note(Map.merge(params, subject_attrs(socket.assigns)))
      |> Map.put(:action, :validate)

    assign(socket, form: to_form(cs, id: "#{socket.assigns.id}_note"), params: params)
  end

  defp notify(%{assigns: %{notify: :liveview, id: id}}, event),
    do: send(self(), {:composer, id, event})

  defp notify(%{assigns: %{notify: {module, cid}, id: id}}, event),
    do: send_update(module, id: cid, composer: {id, event})

  # --- events ---------------------------------------------------------------

  @impl true
  def handle_event("validate", %{"note" => params}, socket),
    do: {:noreply, change(socket, params)}

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

  defp errors(form) do
    Enum.map(
      form[:body].errors ++
        form[:subject_id].errors ++ form[:subject_type].errors ++ form[:visibility].errors ++
        form[:reply_to_id].errors,
      &FullCircleWeb.CoreComponents.translate_error/1
    )
  end

  @impl true
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
          <p
            :if={@replying}
            id={"#{@id}-reply-scope"}
            class="pb-1 text-xs text-slate-500 dark:text-slate-400"
          >
            {gettext("Visible to the same people as the note it replies to.")}
          </p>

          <div
            :if={@show_roles and not @replying and not task_subject?(@subject, @fixed_subject)}
            class="flex flex-wrap items-center gap-1 pb-2 text-xs"
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
            <input
              :for={role <- roles_of(@form)}
              type="hidden"
              name="note[visibility][]"
              value={role}
            />
          </div>
          <p
            :if={@hint && not @replying && not task_subject?(@subject, @fixed_subject)}
            class="pb-1 text-xs text-slate-500 dark:text-slate-400"
          >
            {@hint}
          </p>

          <div class="flex flex-wrap items-center gap-1 border-t border-gray-200 pt-2 dark:border-gray-700">
            <.record_chip
              :if={@subject && !@fixed_subject && !@replying}
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
              :if={
                !@fixed_subject and
                  ((not @replying and (is_nil(@subject) or @full)) or (@replying and @full))
              }
              id={"#{@id}-open-picker"}
              type="button"
              phx-click="toggle_picker"
              phx-target={@myself}
              class={[
                "rounded-full border px-2 text-xs",
                if(is_nil(@subject) and not @replying,
                  do:
                    "border-amber-400 bg-amber-50 text-amber-900 dark:border-amber-600 dark:bg-amber-950 dark:text-amber-100",
                  else:
                    "border-dashed border-gray-400 text-gray-600 dark:border-gray-500 dark:text-gray-300"
                )
              ]}
            >
              ＋ {if @subject || @replying, do: gettext("link a record"), else: gettext("about…")}
            </button>
            <button
              :if={(@compact or !@show_roles) and not @replying}
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
              if @subject || @replying,
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
