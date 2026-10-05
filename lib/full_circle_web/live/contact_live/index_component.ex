defmodule FullCircleWeb.ContactLive.IndexComponent do
  use FullCircleWeb, :live_component

  import FullCircleWeb.ListComponents

  @impl true
  def mount(socket) do
    {:ok, socket}
  end

  @impl true
  def update(assigns, socket) do
    {:ok, socket |> assign(assigns) |> assign_new(:note_count, fn -> 0 end)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class={[row_class(@ex_class), line_class()]}>
      <div
        class="w-[24%] shrink-0 min-w-0 flex items-center gap-1 overflow-hidden"
        title={@obj.contact_info}
      >
        <.link
          :if={!FullCircle.Accounting.is_default_account?(@obj)}
          class="min-w-0 truncate hover:font-bold text-blue-600"
          navigate={~p"/companies/#{@current_company.id}/contacts/#{@obj.id}/edit"}
        >
          {@obj.name}
        </.link>
        <span :if={FullCircle.Accounting.is_default_account?(@obj)} class="min-w-0 truncate">
          {@obj.name}
        </span>
        <.row_notes_badge count={@note_count} tasks={@task_count} id={@obj.id} />
      </div>
      <div class="w-[11%] shrink-0 truncate">{@obj.category}</div>
      <div class={["flex-1 min-w-0 truncate", muted_class()]} title={address(@obj)}>
        {address(@obj)}
      </div>
      <div class="w-[12%] shrink-0 truncate">{@obj.phone}</div>
      <div class="w-[16%] shrink-0 truncate" title={@obj.email}>{@obj.email}</div>
      <div class={["w-[14%] shrink-0 truncate", muted_class()]} title={@obj.descriptions}>
        {@obj.descriptions}
      </div>
    </div>
    """
  end

  defp address(obj) do
    [
      obj.address1,
      obj.address2,
      Enum.join(Enum.reject([obj.city, obj.zipcode], &(&1 in [nil, ""])), " "),
      obj.state,
      obj.country
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(", ")
  end
end
