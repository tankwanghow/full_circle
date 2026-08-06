defmodule FullCircleWeb.CommandPaletteComponent do
  @moduledoc """
  App-wide command palette (Ctrl/Cmd+K).
  """
  use FullCircleWeb, :live_component

  alias FullCircle.CommandPalette
  alias FullCircle.CommandPalette.Groups

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:open?, false)
     |> assign(:terms, "")
     |> assign(:hits, [])
     |> assign(:groups, [])
     |> assign(:selected, 0)
     |> assign(:cheatsheet, CommandPalette.cheatsheet_lines())}
  end

  @impl true
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:open?, fn -> false end)
     |> assign_new(:terms, fn -> "" end)
     |> assign_new(:hits, fn -> [] end)
     |> assign_new(:groups, fn -> [] end)
     |> assign_new(:selected, fn -> 0 end)
     |> assign_new(:cheatsheet, fn -> CommandPalette.cheatsheet_lines() end)}
  end

  @impl true
  def handle_event("open", _params, socket) do
    {:noreply,
     socket
     |> assign(:open?, true)
     |> assign(:terms, "")
     |> assign(:hits, [])
     |> assign(:groups, [])
     |> assign(:selected, 0)
     |> push_event("palette_load_recents", %{
       company_id: socket.assigns.current_company.id
     })}
  end

  def handle_event("close", _params, socket) do
    {:noreply, close(socket)}
  end

  def handle_event("go_dashboard", _params, socket) do
    path = ~p"/companies/#{socket.assigns.current_company.id}/dashboard"

    {:noreply,
     socket
     |> close()
     |> push_navigate(to: path)}
  end

  def handle_event("recents", %{"items" => items}, socket) do
    recents = CommandPalette.recents_from_payload(items)
    actions = CommandPalette.empty_hits(socket.assigns.current_company, socket.assigns.current_user)
    hits = recents ++ actions
    set_hits(socket, hits, "")
  end

  def handle_event("search", %{"terms" => terms}, socket) do
    terms = terms || ""

    hits =
      if String.trim(terms) == "" do
        []
      else
        CommandPalette.search(
          socket.assigns.current_company,
          socket.assigns.current_user,
          terms
        )
      end

    socket =
      if String.trim(terms) == "" do
        push_event(socket, "palette_load_recents", %{
          company_id: socket.assigns.current_company.id
        })
      else
        socket
      end

    set_hits(socket, hits, terms)
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

  # Enter → edit (Alt+Enter is handled via JS → print_selected; see hook)
  def handle_event("keydown", %{"key" => "Enter"} = params, socket) do
    if alt_pressed?(params) do
      print_selected(socket)
    else
      case Enum.at(socket.assigns.hits, socket.assigns.selected) do
        nil -> {:noreply, socket}
        hit -> navigate_hit(socket, hit, hit.path)
      end
    end
  end

  def handle_event("keydown", _params, socket), do: {:noreply, socket}

  def handle_event("print_selected", _params, socket) do
    print_selected(socket)
  end

  def handle_event("select", %{"index" => index}, socket) do
    index = String.to_integer(index)

    case Enum.at(socket.assigns.hits, index) do
      nil -> {:noreply, socket}
      hit -> navigate_hit(socket, hit, hit.path)
    end
  end

  def handle_event("print", %{"index" => index}, socket) do
    index = String.to_integer(index)

    case Enum.at(socket.assigns.hits, index) do
      %{print_path: path} = hit when is_binary(path) and path != "" ->
        navigate_hit(socket, hit, path)

      _ ->
        {:noreply, socket}
    end
  end

  defp print_selected(socket) do
    case Enum.at(socket.assigns.hits, socket.assigns.selected) do
      %{print_path: path} = hit when is_binary(path) and path != "" ->
        navigate_hit(socket, hit, path)

      _ ->
        {:noreply, socket}
    end
  end

  defp alt_pressed?(%{"altKey" => v}) when v in [true, "true"], do: true
  defp alt_pressed?(_), do: false

  def handle_event("hover", %{"index" => index}, socket) do
    {:noreply, assign(socket, :selected, String.to_integer(index))}
  end

  defp set_hits(socket, hits, terms) do
    groups = CommandPalette.group_hits(hits)
    flat = Groups.flatten(groups)

    {:noreply,
     socket
     |> assign(:terms, terms)
     |> assign(:hits, flat)
     |> assign(:groups, groups)
     |> assign(:selected, 0)}
  end

  defp navigate_hit(socket, hit, path) do
    remember = %{
      path: hit.path,
      print_path: hit.print_path,
      title: primary_text(hit),
      label: hit.label,
      doc_type: hit.doc_type,
      doc_id: hit.doc_id,
      company_id: socket.assigns.current_company.id
    }

    socket =
      socket
      |> push_event("palette_remember", remember)
      |> close()

    # Print lives in a different live_session (print_root) — full redirect required
    if print_url?(path) do
      {:noreply, redirect(socket, to: path)}
    else
      {:noreply, push_navigate(socket, to: path)}
    end
  end

  defp print_url?(path) when is_binary(path), do: String.contains?(path, "/print")
  defp print_url?(_), do: false

  defp close(socket) do
    socket
    |> assign(:open?, false)
    |> assign(:terms, "")
    |> assign(:hits, [])
    |> assign(:groups, [])
    |> assign(:selected, 0)
  end

  defp subtitle(%{kind: :action, contact_name: key}) when is_binary(key) do
    gettext("Create · type %{key}", key: key)
  end

  defp subtitle(%{kind: :contact}) do
    gettext("Open contact master")
  end

  defp subtitle(%{kind: :recent}) do
    gettext("Recent")
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

    account =
      case Map.get(hit, :bank_name) do
        name when is_binary(name) and name != "" -> name
        _ -> nil
      end

    print_hint =
      if is_binary(hit.print_path) and hit.print_path != "" do
        gettext("Alt+↵ print")
      else
        nil
      end

    [date, hit.contact_name, account, good, print_hint]
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.join(" · ")
  end

  defp primary_text(%{kind: :action, doc_no: title}), do: title
  defp primary_text(%{kind: :contact, doc_no: name}), do: name
  defp primary_text(%{kind: :recent, doc_no: title}), do: title
  defp primary_text(%{doc_no: no}), do: no

  defp badge_class(:action), do: "bg-sky-800 text-sky-200"
  defp badge_class(:contact), do: "bg-violet-800 text-violet-200"
  defp badge_class(:recent), do: "bg-amber-900 text-amber-200"
  defp badge_class(_), do: "bg-gray-700 text-amber-300"

  defp empty_terms?(terms), do: String.trim(terms || "") == ""
  defp has_print?(%{print_path: p}) when is_binary(p) and p != "", do: true
  defp has_print?(_), do: false

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id={@id}
      phx-hook="CommandPalette"
      phx-target={@myself}
      data-open={to_string(@open?)}
      data-selected={@selected}
      data-company-id={@current_company.id}
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
                placeholder={gettext("Search or newinv / newdep / newrtn…")}
                class="w-full bg-transparent border-0 text-white placeholder:text-gray-500 focus:ring-0 focus:outline-none py-2"
                autocomplete="off"
                autofocus
              />
              <kbd class="hidden sm:inline text-xs text-gray-500 border border-gray-600 rounded px-1.5 py-0.5">
                esc
              </kbd>
            </div>
          </form>

          <div
            :if={empty_terms?(@terms) and @groups == []}
            class="px-4 py-6 text-center text-gray-400 text-sm"
          >
            {gettext("Loading…")}
          </div>

          <%!-- Empty palette: recents/actions already in groups; always show cheatsheet strip --%>
          <div
            :if={empty_terms?(@terms) and @groups != []}
            class="border-b border-gray-800 px-3 py-2 text-[11px] text-gray-500 space-y-0.5"
          >
            <p :for={line <- @cheatsheet} class="truncate">{line}</p>
          </div>

          <div
            :if={@groups != [] or (not empty_terms?(@terms) and String.length(String.trim(@terms)) >= 2)}
            id={"#{@id}-results"}
            class="max-h-80 overflow-y-auto py-1"
            role="listbox"
          >
            <div
              :if={not empty_terms?(@terms) and String.length(String.trim(@terms)) >= 2 and @hits == []}
              class="px-4 py-6 text-center text-gray-400 text-sm"
            >
              {gettext("No matches")}
            </div>

            <%= for {section, section_hits} <- @groups do %>
              <% base = flat_offset(@groups, section) %>
              <div class="px-3 pt-2 pb-1 text-[10px] font-semibold uppercase tracking-wider text-gray-500">
                {Groups.section_label(section)}
              </div>
              <div
                :for={{hit, i} <- Enum.with_index(section_hits)}
                id={"#{@id}-hit-#{base + i}"}
                role="option"
                aria-selected={to_string(@selected == base + i)}
                data-selected={to_string(@selected == base + i)}
                class={[
                  "flex cursor-pointer items-center gap-3 px-3 py-2 text-sm",
                  @selected == base + i && "bg-emerald-700/80",
                  @selected != base + i && "hover:bg-gray-800"
                ]}
                phx-click="select"
                phx-value-index={base + i}
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
                <button
                  :if={has_print?(hit)}
                  type="button"
                  class="shrink-0 rounded px-1.5 py-0.5 text-[10px] text-gray-300 hover:bg-gray-700 border border-gray-600"
                  phx-click="print"
                  phx-value-index={base + i}
                  phx-target={@myself}
                  title={gettext("Print (Alt+Enter)")}
                >
                  {gettext("Print")}
                </button>
                <.icon
                  :if={@selected == base + i and not has_print?(hit)}
                  name="hero-arrow-right"
                  class="w-4 h-4 text-gray-300 shrink-0"
                />
              </div>
            <% end %>
          </div>

          <div class="border-t border-gray-700 px-3 py-2 text-xs text-gray-500 flex flex-wrap gap-x-3 gap-y-1">
            <span><kbd class="border border-gray-600 rounded px-1">↑↓</kbd> {gettext("navigate")}</span>
            <span><kbd class="border border-gray-600 rounded px-1">↵</kbd> {gettext("edit")}</span>
            <span>
              <kbd class="border border-gray-600 rounded px-1">Alt+↵</kbd> {gettext("print")}
            </span>
            <span><kbd class="border border-gray-600 rounded px-1">esc</kbd> {gettext("close")}</span>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp flat_offset(groups, section) do
    groups
    |> Enum.take_while(fn {sec, _} -> sec != section end)
    |> Enum.reduce(0, fn {_s, hits}, acc -> acc + length(hits) end)
  end
end
