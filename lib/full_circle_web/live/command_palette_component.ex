defmodule FullCircleWeb.CommandPaletteComponent do
  @moduledoc """
  App-wide command palette (Ctrl/Cmd+K).

  Search documents/contacts, or run create actions (`newinv`, `newpur`, …).
  """
  use FullCircleWeb, :live_component

  alias FullCircle.CommandPalette

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:open?, false)
     |> assign(:terms, "")
     |> assign(:hits, [])
     |> assign(:selected, 0)}
  end

  @impl true
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:open?, fn -> false end)
     |> assign_new(:terms, fn -> "" end)
     |> assign_new(:hits, fn -> [] end)
     |> assign_new(:selected, fn -> 0 end)}
  end

  @impl true
  def handle_event("open", _params, socket) do
    {:noreply,
     socket
     |> assign(:open?, true)
     |> assign(:terms, "")
     |> assign(:hits, [])
     |> assign(:selected, 0)}
  end

  def handle_event("close", _params, socket) do
    {:noreply, close(socket)}
  end

  def handle_event("search", %{"terms" => terms}, socket) do
    hits =
      CommandPalette.search(
        socket.assigns.current_company,
        socket.assigns.current_user,
        terms
      )

    {:noreply,
     socket
     |> assign(:terms, terms)
     |> assign(:hits, hits)
     |> assign(:selected, 0)}
  end

  def handle_event("keydown", %{"key" => "Escape"}, socket) do
    {:noreply, close(socket)}
  end

  def handle_event("keydown", %{"key" => "ArrowDown"}, socket) do
    max = max(length(socket.assigns.hits) - 1, 0)
    sel = min(socket.assigns.selected + 1, max)
    {:noreply, assign(socket, :selected, sel)}
  end

  def handle_event("keydown", %{"key" => "ArrowUp"}, socket) do
    sel = max(socket.assigns.selected - 1, 0)
    {:noreply, assign(socket, :selected, sel)}
  end

  def handle_event("keydown", %{"key" => "Enter"}, socket) do
    case Enum.at(socket.assigns.hits, socket.assigns.selected) do
      nil -> {:noreply, socket}
      hit -> {:noreply, socket |> close() |> push_navigate(to: hit.path)}
    end
  end

  def handle_event("keydown", _params, socket), do: {:noreply, socket}

  def handle_event("select", %{"index" => index}, socket) do
    index = String.to_integer(index)

    case Enum.at(socket.assigns.hits, index) do
      nil -> {:noreply, socket}
      hit -> {:noreply, socket |> close() |> push_navigate(to: hit.path)}
    end
  end

  def handle_event("hover", %{"index" => index}, socket) do
    {:noreply, assign(socket, :selected, String.to_integer(index))}
  end

  defp close(socket) do
    socket
    |> assign(:open?, false)
    |> assign(:terms, "")
    |> assign(:hits, [])
    |> assign(:selected, 0)
  end

  defp subtitle(%{kind: :action, contact_name: key}) when is_binary(key) do
    gettext("Create · type %{key}", key: key)
  end

  defp subtitle(%{kind: :contact}) do
    gettext("Open contact master")
  end

  defp subtitle(hit) do
    date =
      case hit.doc_date do
        %Date{} = d -> Calendar.strftime(d, "%d/%m/%Y")
        _ -> nil
      end

    good =
      case hit.good_name do
        name when is_binary(name) and name != "" -> name
        _ -> nil
      end

    [date, hit.contact_name, good]
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.join(" · ")
  end

  defp primary_text(%{kind: :action, doc_no: title}), do: title
  defp primary_text(%{kind: :contact, doc_no: name}), do: name
  defp primary_text(%{doc_no: no}), do: no

  defp badge_class(:action), do: "bg-sky-800 text-sky-200"
  defp badge_class(:contact), do: "bg-violet-800 text-violet-200"
  defp badge_class(_), do: "bg-gray-700 text-amber-300"

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id={@id}
      phx-hook="CommandPalette"
      phx-target={@myself}
      data-open={to_string(@open?)}
    >
      <div
        :if={@open?}
        id={"#{@id}-overlay"}
        class="fixed inset-0 z-[100] flex items-start justify-center bg-black/50 pt-[12vh] px-4"
        phx-click="close"
        phx-window-keydown="keydown"
        phx-target={@myself}
      >
        <div
          class="w-full max-w-xl rounded-lg border border-gray-600 bg-gray-900 shadow-2xl text-white"
          onclick="event.stopPropagation()"
        >
          <form phx-change="search" phx-submit="search" phx-target={@myself} autocomplete="off">
            <div class="flex items-center gap-2 border-b border-gray-700 px-3 py-2">
              <.icon name="hero-magnifying-glass" class="w-5 h-5 text-gray-400 shrink-0" />
              <input
                id={"#{@id}-input"}
                type="search"
                name="terms"
                value={@terms}
                phx-debounce="250"
                placeholder={gettext("Docs, contact, good, dates, or newinv…")}
                class="w-full bg-transparent border-0 text-white placeholder:text-gray-500 focus:ring-0 focus:outline-none py-2"
                autocomplete="off"
                autofocus
              />
              <kbd class="hidden sm:inline text-xs text-gray-500 border border-gray-600 rounded px-1.5 py-0.5">
                esc
              </kbd>
            </div>
          </form>

          <ul
            :if={@terms != "" and String.length(String.trim(@terms)) >= 2}
            id={"#{@id}-results"}
            class="max-h-80 overflow-y-auto py-1"
            role="listbox"
          >
            <li
              :if={@hits == []}
              class="px-4 py-6 text-center text-gray-400 text-sm"
            >
              {gettext("No matches")}
            </li>
            <li
              :for={{hit, index} <- Enum.with_index(@hits)}
              id={"#{@id}-hit-#{index}"}
              role="option"
              aria-selected={@selected == index}
              class={[
                "flex cursor-pointer items-center gap-3 px-3 py-2 text-sm",
                @selected == index && "bg-emerald-700/80",
                @selected != index && "hover:bg-gray-800"
              ]}
              phx-click="select"
              phx-value-index={index}
              phx-target={@myself}
              phx-mouseover="hover"
            >
              <span class={[
                "shrink-0 rounded px-2 py-0.5 text-xs font-medium w-28 text-center truncate",
                badge_class(hit.kind)
              ]}>
                {hit.label}
              </span>
              <div class="min-w-0 flex-1">
                <div class="font-semibold truncate">{primary_text(hit)}</div>
                <div :if={subtitle(hit) != ""} class="text-xs text-gray-400 truncate">
                  {subtitle(hit)}
                </div>
              </div>
              <.icon
                :if={@selected == index}
                name="hero-arrow-right"
                class="w-4 h-4 text-gray-300 shrink-0"
              />
            </li>
          </ul>

          <div class="border-t border-gray-700 px-3 py-2 text-xs text-gray-500 flex flex-wrap gap-x-3 gap-y-1">
            <span><kbd class="border border-gray-600 rounded px-1">↑↓</kbd> {gettext("navigate")}</span>
            <span><kbd class="border border-gray-600 rounded px-1">↵</kbd> {gettext("open")}</span>
            <span><kbd class="border border-gray-600 rounded px-1">esc</kbd> {gettext("close")}</span>
            <span class="text-gray-600">
              {gettext("e.g. swee inv good grade e · newinv · INV-…")}
            </span>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
