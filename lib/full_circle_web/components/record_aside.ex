defmodule FullCircleWeb.RecordAside do
  @moduledoc """
  Under a record's card: notes on the left, tasks linked to that record on
  the right. The row takes the card's width. The columns sit side by side
  once that width reaches 56rem (`@4xl`); a narrower card stacks, notes first.
  Either way each panel is as tall as its own content.
  """
  use FullCircleWeb, :html

  alias FullCircleWeb.TaskLive.TasksPanelComponent

  @doc """
  `on_mount {FullCircleWeb.RecordAside, :refresh_tasks_panel}` in every page
  that renders `record_aside/1`. A task saved elsewhere (the full form in a new
  tab, another user) broadcasts `{:tasks_changed, company_id}` on
  `Tasks.topic/1`; this subscribes the page and hands that message to the
  tasks panel, so the host LiveView needs no handle_info of its own.
  """
  def on_mount(:refresh_tasks_panel, _params, _session, socket) do
    company = socket.assigns[:current_company]

    if company && Phoenix.LiveView.connected?(socket) do
      Phoenix.PubSub.subscribe(FullCircle.PubSub, FullCircle.Tasks.topic(company.id))

      {:cont,
       Phoenix.LiveView.attach_hook(socket, :refresh_tasks_panel, :handle_info, &refresh/2)}
    else
      {:cont, socket}
    end
  end

  defp refresh({:tasks_changed, _company_id}, socket) do
    Phoenix.LiveView.send_update(TasksPanelComponent, id: "tasks-panel", refresh: true)
    {:halt, socket}
  end

  defp refresh(_msg, socket), do: {:cont, socket}

  attr :record_type, :string, required: true
  attr :record_id, :string, required: true
  attr :class, :any, default: nil
  attr :current_company, :map, required: true
  attr :current_user, :map, required: true

  def record_aside(assigns) do
    ~H"""
    <%!-- A container query sizes against an ancestor, never the element that
         declares @container: the row lives one level in. Each panel keeps
         its own height; flex-1 only splits the width once side by side. --%>
    <div id={"record-aside-#{@record_type}"} class={["@container mx-auto mt-3", @class]}>
      <div class="flex flex-col gap-1 @4xl:flex-row @4xl:items-start">
        <.live_component
          module={FullCircleWeb.NoteLive.NotesPanelComponent}
          id="notes-panel"
          record_type={@record_type}
          record_id={@record_id}
          current_company={@current_company}
          current_user={@current_user}
          class="min-w-0 w-full @4xl:flex-1"
        />
        <.live_component
          module={FullCircleWeb.TaskLive.TasksPanelComponent}
          id="tasks-panel"
          record_type={@record_type}
          record_id={@record_id}
          current_company={@current_company}
          current_user={@current_user}
          class="min-w-0 w-full @4xl:flex-1"
        />
      </div>
    </div>
    """
  end
end
