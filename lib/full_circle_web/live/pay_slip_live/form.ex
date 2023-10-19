defmodule FullCircleWeb.PaySlipLive.Form do
  use FullCircleWeb, :live_view

  alias FullCircle.HR.PaySlip
  alias FullCircle.PaySlip

  @impl true
  def mount(params, _session, socket) do
    month = params["month"]
    year = params["year"]
    emp_id = params["emp_id"]
    id = params[:id]

    socket =
      case socket.assigns.live_action do
        :new -> mount_new(socket, emp_id, month, year)
        :edit -> mount_edit(socket, id)
      end

    {:ok, socket}
  end

  defp mount_new(socket, emp_id, month, year) do
    socket
    |> assign(live_action: :new)
    |> assign(id: "new")
    |> assign(page_title: gettext("New Pay Slip"))
    |> assign(
      form:
        to_form(
          PaySlip.generate_new_changeset_for(
            emp_id,
            month,
            year,
            socket.assigns.current_company,
            socket.assigns.current_user
          )
        )
    )
  end

  defp mount_edit(socket, id) do
    socket
    # obj =
    #   HR.get_salary_note!(id, socket.assigns.current_company, socket.assigns.current_user)

    # socket
    # |> assign(live_action: :edit)
    # |> assign(id: id)
    # |> assign(page_title: gettext("Edit Pay Slip") <> " " <> obj.slip_no)
    # |> assign(
    #   :form,
    # )
  end
end
