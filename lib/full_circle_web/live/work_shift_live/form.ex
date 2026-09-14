defmodule FullCircleWeb.WorkShiftLive.Form do
  use FullCircleWeb, :live_view

  alias FullCircle.Authorization
  alias FullCircle.HR
  alias FullCircle.HR.WorkShift
  alias FullCircle.StdInterface

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto w-6/12">
      <p class="w-full text-2xl text-center font-medium">{@page_title}</p>
      <.form
        for={@form}
        id="work-shift-form"
        phx-change="validate"
        phx-submit="save"
        autocomplete="off"
      >
        <.input field={@form[:name]} label={gettext("Name")} />
        <.input field={@form[:start_time]} type="time" label={gettext("Starts")} />
        <.input field={@form[:normal_hour]} type="number" step="0.25" label={gettext("Normal Hour")} />
        <.input field={@form[:max_hour]} type="number" step="0.25" label={gettext("Max Hour")} />
        <p class="mt-2 text-sm text-gray-600 dark:text-gray-400">
          {gettext(
            "Normal Hour sets the displayed end time only. Max Hour is the tolerance: a shift longer than this is flagged, and it also places the cutover that separates one shift from the next."
          )}
        </p>
        <p :if={@derived} class="mt-1 text-sm font-medium">
          {gettext("Nominal end")}: {@derived.nominal_end} · {gettext("Cutover")}: {@derived.cutover}
        </p>
        <div class="text-center mt-3">
          <.button phx-disable-with={gettext("Saving...")}>{gettext("Save")}</.button>
          <.link navigate={~p"/companies/#{@current_company.id}/work_shifts"} class="orange button">
            {gettext("Back")}
          </.link>
          <%= if @obj.id && not @obj.is_default &&
                 Authorization.can?(@current_user, :delete_work_shift, @current_company) do %>
            <.delete_confirm_modal
              id="delete-work-shift"
              msg1={gettext("This work shift will be deleted.")}
              msg2={gettext("Cannot Be Recover!!!")}
              confirm={JS.push("delete") |> JS.hide(to: "#delete-work-shift-modal")}
            />
          <% end %>
        </div>
      </.form>
    </div>
    """
  end

  @impl true
  def mount(params, _session, socket) do
    company = socket.assigns.current_company

    if Authorization.can?(socket.assigns.current_user, :update_work_shift, company) do
      obj =
        case params["work_shift_id"] do
          nil ->
            %WorkShift{
              start_time: ~T[08:00:00],
              normal_hour: Decimal.new("9"),
              max_hour: Decimal.new("12")
            }

          id ->
            StdInterface.get!(WorkShift, id)
        end

      {:ok,
       socket
       |> assign(
         page_title: if(obj.id, do: gettext("Edit Work Shift"), else: gettext("New Work Shift"))
       )
       |> assign(obj: obj)
       |> assign_form(WorkShift.changeset(obj, %{}))}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("Not Authorized!"))
       |> push_navigate(to: ~p"/companies/#{company.id}/dashboard")}
    end
  end

  @impl true
  def handle_event("validate", %{"work_shift" => attrs}, socket) do
    cs = WorkShift.changeset(socket.assigns.obj, attrs) |> Map.put(:action, :validate)
    {:noreply, assign_form(socket, cs)}
  end

  @impl true
  def handle_event("save", %{"work_shift" => attrs}, socket) do
    company = socket.assigns.current_company
    user = socket.assigns.current_user
    obj = socket.assigns.obj

    case HR.save_work_shift(obj, attrs, company, user) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Saved."))
         |> push_navigate(to: ~p"/companies/#{company.id}/work_shifts")}

      :not_authorise ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Not Authorized!"))
         |> push_navigate(to: ~p"/companies/#{company.id}/dashboard")}

      {:error, _, cs, _} ->
        {:noreply, assign_form(socket, cs)}

      {:error, cs} ->
        {:noreply, assign_form(socket, cs)}
    end
  end

  @impl true
  def handle_event("delete", _params, socket) do
    company = socket.assigns.current_company

    case HR.delete_work_shift(
           socket.assigns.obj,
           company,
           socket.assigns.current_user
         ) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Deleted."))
         |> push_navigate(to: ~p"/companies/#{company.id}/work_shifts")}

      {:error, :default_shift} ->
        {:noreply, put_flash(socket, :error, gettext("The default shift cannot be deleted."))}

      {:error, :shift_in_use} ->
        {:noreply, put_flash(socket, :error, gettext("This shift still has punches."))}

      {:error, :shift_assigned} ->
        {:noreply, put_flash(socket, :error, gettext("This shift is still assigned."))}

      :not_authorise ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Not Authorized!"))
         |> push_navigate(to: ~p"/companies/#{company.id}/dashboard")}

      {:error, _, cs, _} ->
        {:noreply, assign_form(socket, cs)}
    end
  end

  defp assign_form(socket, cs) do
    obj = Ecto.Changeset.apply_changes(cs)

    derived =
      if obj.start_time && obj.normal_hour && obj.max_hour do
        %{
          nominal_end: Calendar.strftime(WorkShift.nominal_end(obj), "%H:%M"),
          cutover: Calendar.strftime(WorkShift.cutover_time(obj), "%H:%M")
        }
      end

    socket |> assign(form: to_form(cs, as: :work_shift)) |> assign(derived: derived)
  end
end
