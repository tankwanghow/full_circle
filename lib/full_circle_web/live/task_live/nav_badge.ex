defmodule FullCircleWeb.TaskLive.NavBadge do
  @moduledoc """
  "✅ Tasks (n)" in the nav, n = open tasks overdue or due soon that I can
  see (the All tab's count). The nav lives in the root layout, which LiveView
  does not re-render on live navigation, so this is a sticky nested LiveView
  that stays mounted across pages and recounts on `{:tasks_changed, _}`.
  The company comes from the session, like `ActiveCompany` (switching company
  is a full page load). Counts can go stale over midnight until the next change.
  """
  use Phoenix.LiveView

  use Gettext, backend: FullCircleWeb.Gettext
  use FullCircleWeb, :verified_routes

  on_mount {FullCircleWeb.UserAuth, :mount_current_user}
  on_mount {FullCircleWeb.Locale, :set_locale}

  alias FullCircle.Tasks

  @impl true
  def mount(_params, session, socket) do
    company =
      session["company_id"] && FullCircle.Repo.get(FullCircle.Sys.Company, session["company_id"])

    user = socket.assigns.current_user

    if (connected?(socket) and company) && user,
      do: Phoenix.PubSub.subscribe(FullCircle.PubSub, Tasks.topic(company.id))

    {:ok, socket |> assign(company: company) |> recount(), layout: false}
  end

  defp recount(%{assigns: %{company: nil}} = socket), do: assign(socket, count: 0)
  defp recount(%{assigns: %{current_user: nil}} = socket), do: assign(socket, count: 0)

  defp recount(socket),
    do:
      assign(socket,
        count: Tasks.badge_counts(socket.assigns.company, socket.assigns.current_user).all
      )

  @impl true
  def handle_info({:tasks_changed, _}, socket), do: {:noreply, recount(socket)}

  @impl true
  def render(assigns) do
    ~H"""
    <.link
      :if={@company && @current_user}
      id="full_circle_tasks"
      navigate={~p"/companies/#{@company.id}/tasks"}
      class="rounded hover:bg-gray-400 p-2 whitespace-nowrap"
    >
      ✅{gettext("Tasks")}<span
        :if={@count > 0}
        id="task-badge-count"
        class="ml-1 rounded-full bg-rose-600 px-1.5 text-xs font-bold text-white"
      >{@count}</span>
    </.link>
    """
  end
end
