defmodule FullCircleWeb.NoteLive.RecordPickerComponent do
  @moduledoc """
  Pick one record of any Linkable type: a type select plus a search box.
  Sends `{:record_picked, id, %{type:, id:, title:}}` to the parent LiveView.
  """
  use FullCircleWeb, :live_component

  import FullCircleWeb.NoteComponents, only: [type_label: 1]

  alias FullCircle.Linkable

  @impl true
  def update(assigns, socket) do
    types = Map.get(assigns, :types) || Linkable.types()

    {:ok,
     socket
     |> assign(assigns)
     |> assign(types: types)
     |> assign_new(:type, fn -> hd(types) end)
     |> assign_new(:terms, fn -> "" end)
     |> assign_new(:results, fn -> [] end)
     |> assign_new(:label, fn -> gettext("Find a record") end)}
  end

  @impl true
  def handle_event("search", %{"type" => type, "terms" => terms}, socket) do
    type = if type in socket.assigns.types, do: type, else: hd(socket.assigns.types)

    results =
      Linkable.search(type, terms, socket.assigns.current_company, socket.assigns.current_user)

    {:noreply, assign(socket, type: type, terms: terms, results: results)}
  end

  def handle_event("pick", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.results, &(&1.id == id)) do
      nil ->
        {:noreply, socket}

      r ->
        send(
          self(),
          {:record_picked, socket.assigns.id, %{type: r.type, id: r.id, title: r.title}}
        )

        {:noreply, assign(socket, terms: "", results: [])}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class="rounded border border-gray-300 p-2 dark:border-gray-600">
      <div class="text-sm font-semibold">{@label}</div>
      <form phx-change="search" phx-submit="search" phx-target={@myself} class="flex gap-1">
        <select name="type" class="rounded border-gray-300 text-sm">
          <option :for={t <- @types} value={t} selected={t == @type}>{type_label(t)}</option>
        </select>
        <input
          type="search"
          name="terms"
          value={@terms}
          phx-debounce="300"
          autocomplete="off"
          placeholder={gettext("Type a name or number...")}
          class="w-full rounded border-gray-300 text-sm"
        />
      </form>
      <div :if={@results != []} class="mt-1 max-h-48 overflow-y-auto">
        <button
          :for={r <- @results}
          type="button"
          id={"#{@id}-pick-#{r.id}"}
          phx-click="pick"
          phx-value-id={r.id}
          phx-target={@myself}
          class="block w-full rounded px-1 text-left text-sm hover:bg-amber-100 dark:hover:bg-amber-900"
        >
          {r.title} <span :if={r.subtitle} class="text-gray-500">— {r.subtitle}</span>
        </button>
      </div>
      <div :if={@results == [] and @terms != ""} class="text-sm text-gray-500">
        {gettext("No match.")}
      </div>
    </div>
    """
  end
end
