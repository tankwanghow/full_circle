defmodule FullCircleWeb.RecordAside do
  @moduledoc """
  Under a record's card: notes on the left, tasks linked to that record on
  the right. The row takes the card's width. The columns sit side by side
  once that width reaches 56rem (`@4xl`); a narrower card stacks, notes first.
  """
  use FullCircleWeb, :html

  attr :record_type, :string, required: true
  attr :record_id, :string, required: true
  attr :class, :any, default: nil
  attr :current_company, :map, required: true
  attr :current_user, :map, required: true

  def record_aside(assigns) do
    ~H"""
    <div
      id={"record-aside-#{@record_type}"}
      class={[
        "@container mx-auto mt-3 flex flex-col gap-3 @4xl:flex-row @4xl:items-start",
        @class
      ]}
    >
      <.live_component
        module={FullCircleWeb.NoteLive.NotesPanelComponent}
        id="notes-panel"
        record_type={@record_type}
        record_id={@record_id}
        current_company={@current_company}
        current_user={@current_user}
        class="min-w-0 w-full flex-1"
      />
      <.live_component
        module={FullCircleWeb.TaskLive.TasksPanelComponent}
        id="tasks-panel"
        record_type={@record_type}
        record_id={@record_id}
        current_company={@current_company}
        current_user={@current_user}
        class="min-w-0 w-full flex-1"
      />
    </div>
    """
  end
end
