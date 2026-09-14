defmodule FullCircleWeb.WorkShiftLive.Index do
  use FullCircleWeb, :live_view

  import Ecto.Query, warn: false

  alias FullCircle.Authorization
  alias FullCircle.HR.WorkShift
  alias FullCircle.Repo
  alias FullCircleWeb.WorkShiftLive.IndexComponent

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto w-8/12">
      <p class="w-full text-3xl text-center font-medium">{@page_title}</p>
      <p class="text-center text-sm mb-2 text-gray-600 dark:text-gray-400">
        {gettext("An employee with no assignment works the default shift.")}
      </p>
      <div class="text-center mb-2">
        <.link navigate={~p"/companies/#{@current_company.id}/work_shifts/new"} class="blue button">
          {gettext("New Work Shift")}
        </.link>
      </div>
      <div class="font-medium flex flex-row text-center tracking-tighter bg-amber-200 dark:bg-amber-800">
        <div class="w-[26%] border-y border-amber-400 py-1">{gettext("Name")}</div>
        <div class="w-[14%] border-y border-amber-400 py-1">{gettext("Starts")}</div>
        <div class="w-[14%] border-y border-amber-400 py-1">{gettext("Nominal End")}</div>
        <div class="w-[14%] border-y border-amber-400 py-1">{gettext("Normal Hour")}</div>
        <div class="w-[14%] border-y border-amber-400 py-1">{gettext("Max Hour")}</div>
        <div class="w-[18%] border-y border-amber-400 py-1">{gettext("Cutover")}</div>
      </div>
      <div id="objects_list">
        <.live_component
          :for={obj <- @objects}
          module={IndexComponent}
          id={obj.id}
          obj={obj}
          current_company={@current_company}
        />
      </div>
    </div>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    company = socket.assigns.current_company

    if Authorization.can?(socket.assigns.current_user, :update_work_shift, company) do
      {:ok,
       socket
       |> assign(page_title: gettext("Work Shifts"))
       |> assign(objects: list_shifts(company))}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("Not Authorized!"))
       |> push_navigate(to: ~p"/companies/#{company.id}/dashboard")}
    end
  end

  defp list_shifts(company) do
    from(w in WorkShift,
      where: w.company_id == ^company.id,
      order_by: [desc: w.is_default, asc: w.name]
    )
    |> Repo.all()
  end
end
