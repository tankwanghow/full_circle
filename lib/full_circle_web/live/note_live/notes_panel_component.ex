defmodule FullCircleWeb.NoteLive.NotesPanelComponent do
  @moduledoc """
  Notes about, or linking to, one record. Rendered under a record's edit form
  and inside the index-page notes modal. Self-contained: all events target it.
  """
  use FullCircleWeb, :live_component

  import FullCircleWeb.NoteComponents

  alias FullCircle.Notes

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

  # The host form re-renders on every keystroke (phx-change="validate"), which
  # calls update/2 each time. Only (re)load when the record changes, or the
  # panel would query per keystroke.
  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:notify_parent, fn -> false end)
      |> assign_new(:class, fn -> nil end)
      |> assign_new(:layout, fn -> :card end)
      |> assign_new(:adding, fn -> false end)
      |> assign_new(:heading, fn -> nil end)

    key = {socket.assigns.record_type, socket.assigns.record_id}

    if socket.assigns[:loaded_for] == key do
      {:ok, socket}
    else
      {:ok, socket |> assign(loaded_for: key, adding: false) |> load()}
    end
  end

  defp load(socket) do
    %{record_type: t, record_id: id, current_company: com, current_user: user} = socket.assigns
    rows = Notes.notes_for_record(t, id, com, user)
    details = Notes.feed_details(Enum.map(rows, & &1.note), com, user)
    # Every row is already visible, so edit rights need no per-note query.
    rights = Notes.rights(com, user)

    items =
      for r <- rows do
        %{
          id: r.note.id,
          note: r.note,
          d: Map.fetch!(details, r.note.id),
          relation: r.relation,
          can_attach: Notes.may_edit?(r.note, user, rights)
        }
      end

    assign(socket, items: items, can_create: rights.create)
  end

  @impl true
  def handle_event("new", _, socket), do: {:noreply, assign(socket, adding: true)}
  def handle_event("cancel", _, socket), do: {:noreply, assign(socket, adding: false)}

  def handle_event("attachment_uploaded", _, socket), do: {:noreply, load(socket)}

  @impl true
  def render(assigns) do
    ~H"""
    <section
      id={@id}
      class={
        if @layout == :card,
          do: [
            "overflow-hidden rounded-xl border border-gray-200 bg-white dark:border-gray-700 dark:bg-gray-900",
            @class
          ],
          else: ["bg-white dark:bg-gray-900", @class]
      }
    >
      <div
        :if={@layout == :card}
        class="flex items-center gap-2 border-b border-gray-200 px-4 py-2 dark:border-gray-700"
      >
        <span class="font-semibold">{@heading || "📝 #{gettext("Notes")}"}</span>
        <span class="text-sm text-gray-500">{length(@items)}</span>
        <.link
          :if={@can_create}
          navigate={"/companies/#{@current_company.id}/notes/new?subject_type=#{@record_type}&subject_id=#{@record_id}"}
          class="ml-auto text-xs text-gray-500 hover:underline dark:text-gray-400"
        >
          {gettext("Full form")}
        </.link>
        <button
          :if={@can_create and !@adding}
          id={"#{@id}-new"}
          type="button"
          phx-click="new"
          phx-target={@myself}
          class={[
            "rounded-full bg-sky-500 px-3 py-0.5 text-sm font-bold text-white hover:bg-sky-600",
            !@can_create && "ml-auto"
          ]}
        >
          ＋ {gettext("Note")}
        </button>
      </div>

      <div
        :if={(@adding or @layout == :thread) and @can_create}
        class="border-b border-gray-200 px-4 py-3 dark:border-gray-700"
      >
        <.live_component
          module={FullCircleWeb.NoteLive.ComposerComponent}
          id={@id}
          notify={{__MODULE__, @id}}
          fixed_subject={{@record_type, @record_id}}
          roles_open={@layout == :card and @record_type != "Task"}
          roles={@record_type != "Task"}
          avatar={@layout == :thread}
          cancellable={@layout == :card}
          placeholder={if @layout == :thread, do: gettext("Post your reply…")}
          submit_label={if @layout == :thread, do: gettext("Reply"), else: gettext("Post")}
          current_company={@current_company}
          current_user={@current_user}
        />
      </div>

      <.note_post
        :for={item <- @items}
        id={"#{@id}-note-#{item.id}"}
        item={item}
        current_company={@current_company}
        host={{@record_type, @record_id}}
        relation={item.relation}
        can_attach={item.can_attach}
        new_tab
        compact
      />
      <p :if={@items == [] and @layout == :card} class="px-4 py-3 text-sm text-gray-500">
        {gettext("No notes yet.")}
      </p>
    </section>
    """
  end
end
