defmodule FullCircleWeb.SalaryTypeLive.IndexComponent do
  use FullCircleWeb, :live_component

  import FullCircleWeb.ListComponents

  @impl true
  def mount(socket) do
    {:ok, socket}
  end

  @impl true
  def update(assigns, socket) do
    {:ok, socket |> assign(assigns)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class={[row_class(@ex_class), line_class()]}>
      <div class="w-[22%] shrink-0 min-w-0 truncate">
        <%= cond do %>
          <% !FullCircle.HR.is_default_salary_type?(@obj) -> %>
            <.link
              class="hover:font-bold text-blue-600"
              navigate={~p"/companies/#{@current_company.id}/salary_types/#{@obj.id}/edit"}
            >
              {@obj.name}
            </.link>
          <% @current_role == "admin" -> %>
            <.link
              class="hover:font-bold text-purple-600"
              navigate={~p"/companies/#{@current_company.id}/salary_types/#{@obj.id}/edit"}
            >
              {@obj.name}
            </.link>
          <% true -> %>
            <span class="font-bold text-rose-600">{@obj.name}</span>
        <% end %>
      </div>
      <div class="w-28 shrink-0">
        <span class={"type-badge px-2 py-0.5 rounded-full text-xs font-semibold #{type_badge_class(@obj.type)}"}>
          {@obj.type}
        </span>
      </div>
      <div class="w-[18%] shrink-0 truncate" title={@obj.db_ac_name}>{@obj.db_ac_name}</div>
      <div class="w-[18%] shrink-0 truncate" title={@obj.cr_ac_name}>{@obj.cr_ac_name}</div>
      <div class={["flex-1 min-w-0 truncate", muted_class()]} title={@obj.cal_func}>
        {@obj.cal_func}
      </div>
      <div class="w-24 shrink-0 truncate font-mono text-xs">{@obj.statutory_code}</div>
    </div>
    """
  end

  # Rows keep a fixed light bg-gray-200 background in both themes, so the
  # badge palette needs no dark: variants. Matches the bundle-import diff pills.
  # Opacity-suffixed classes: app.css remaps plain bg-*-200 / text-*-800 in
  # dark mode with selectors that beat dark: variants.
  defp type_badge_class(type), do: badge_colour(type)

  defp badge_colour("Addition"),
    do: "bg-green-100/80 text-green-900 dark:bg-green-900/50 dark:text-green-300"

  defp badge_colour("FixedWages"),
    do: "bg-teal-100/80 text-teal-900 dark:bg-teal-900/50 dark:text-teal-300"

  defp badge_colour("Deduction"),
    do: "bg-rose-100/80 text-rose-900 dark:bg-rose-900/50 dark:text-rose-300"

  defp badge_colour("Contribution"),
    do: "bg-amber-100/80 text-amber-900 dark:bg-amber-900/50 dark:text-amber-300"

  defp badge_colour("Bonus"),
    do: "bg-sky-100/80 text-sky-900 dark:bg-sky-900/50 dark:text-sky-300"

  defp badge_colour("LeaveTaken"),
    do: "bg-violet-100/80 text-violet-900 dark:bg-violet-900/50 dark:text-violet-300"

  defp badge_colour(_), do: "bg-slate-100/80 text-slate-700 dark:bg-gray-800 dark:text-slate-300"
end
