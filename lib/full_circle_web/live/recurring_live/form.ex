defmodule FullCircleWeb.RecurringLive.Form do
  use FullCircleWeb, :live_view

  alias FullCircle.HR.{Recurring}
  alias FullCircle.HR
  alias FullCircle.StdInterface

  @impl true
  def mount(params, _session, socket) do
    id = params["recur_id"]

    socket =
      case socket.assigns.live_action do
        :new -> mount_new(socket)
        :edit -> mount_edit(socket, id)
      end

    {:ok, socket}
  end

  defp mount_new(socket) do
    socket
    |> assign(live_action: :new)
    |> assign(id: "new")
    |> assign(page_title: gettext("New Recurring"))
    |> assign(
      :form,
      to_form(
        StdInterface.changeset(Recurring, %Recurring{}, %{recur_no: "RECU-#{FullCircle.Helpers.gen_temp_id(6)}"}, socket.assigns.current_company)
      )
    )
  end

  defp mount_edit(socket, id) do
    obj =
      HR.get_recurring!(id, socket.assigns.current_company, socket.assigns.current_user)

    socket
    |> assign(live_action: :edit)
    |> assign(id: id)
    |> assign(page_title: gettext("Edit Recurring") <> " " <> obj.recur_no)
    |> assign(
      :form,
      to_form(StdInterface.changeset(Recurring, obj, %{}, socket.assigns.current_company))
    )
  end

  def handle_event(
        "validate",
        %{"_target" => ["recurring", "employee_name"], "recurring" => params},
        socket
      ) do
    {params, socket, _} =
      FullCircleWeb.Helpers.assign_autocomplete_id(
        socket,
        params,
        "employee_name",
        "employee_id",
        &FullCircle.HR.get_employee_by_name/3
      )

    validate(params, socket)
  end

  def handle_event(
        "validate",
        %{"_target" => ["recurring", "salary_type_name"], "recurring" => params},
        socket
      ) do
    {params, socket, _} =
      FullCircleWeb.Helpers.assign_autocomplete_id(
        socket,
        params,
        "salary_type_name",
        "salary_type_id",
        &FullCircle.HR.get_salary_type_by_name/3
      )

    validate(params, socket)
  end

  def handle_event("validate", %{"recurring" => params}, socket) do
    validate(params, socket)
  end

  @impl true
  def handle_event("save", %{"recurring" => params}, socket) do
    save(socket, socket.assigns.live_action, params)
  end

  defp save(socket, :new, params) do
    case StdInterface.create(
           Recurring,
           "recurring",
           params,
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, ac} ->
        {:noreply,
         socket
         |> push_navigate(
           to: ~p"/companies/#{socket.assigns.current_company.id}/recurrings/#{ac.id}/edit"
         )
         |> put_flash(:info, "#{gettext("Recurring created successfully.")}")}

      {:error, failed_operation, changeset, _} ->
        {:noreply,
         socket
         |> assign(form: to_form(changeset))
         |> put_flash(
           :error,
           "#{gettext("Failed")} #{failed_operation}. #{list_errors_to_string(changeset.errors)}"
         )}

      :not_authorise ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("You are not authorised to perform this action"))}
    end
  end

  defp save(socket, :edit, params) do
    case StdInterface.update(
           Recurring,
           "recurring",
           socket.assigns.form.data,
           params,
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, ac} ->
        {:noreply,
         socket
         |> push_navigate(
           to: ~p"/companies/#{socket.assigns.current_company.id}/recurrings/#{ac.id}/edit"
         )
         |> put_flash(:info, "#{gettext("Recurring updated successfully.")}")}

      {:error, failed_operation, changeset, _} ->
        {:noreply,
         socket
         |> assign(form: to_form(changeset))
         |> put_flash(
           :error,
           "#{gettext("Failed")} #{failed_operation}. #{list_errors_to_string(changeset.errors)}"
         )}

      :not_authorise ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("You are not authorised to perform this action"))}
    end
  end

  defp validate(params, socket) do
    changeset =
      StdInterface.changeset(
        Recurring,
        socket.assigns.form.data,
        params,
        socket.assigns.current_company
      )
      |> Map.put(:action, socket.assigns.live_action)

    socket = assign(socket, form: to_form(changeset))

    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="w-6/12 mx-auto border rounded-lg border-yellow-500 bg-yellow-100 p-4">
      <p class="w-full text-3xl text-center font-medium"><%= @page_title %></p>
      <.form
        for={@form}
        id="object-form"
        autocomplete="off"
        phx-change="validate"
        phx-submit="save"
        class="mx-auto"
      >
        <%= Phoenix.HTML.Form.hidden_input(@form, :recur_no) %>
        <div class="grid grid-cols-12 gap-1">
          <div class="col-span-3">
            <.input field={@form[:recur_date]} label={gettext("Date")} type="date" />
          </div>
          <div class="col-span-5">
            <%= Phoenix.HTML.Form.hidden_input(@form, :employee_id) %>
            <.input
              field={@form[:employee_name]}
              label={gettext("Employee")}
              phx-hook="tributeAutoComplete"
              phx-debounce="500"
              url={"/api/companies/#{@current_company.id}/#{@current_user.id}/autocomplete?schema=employee&name="}
            />
          </div>
          <div class="col-span-4">
            <%= Phoenix.HTML.Form.hidden_input(@form, :salary_type_id) %>
            <.input
              field={@form[:salary_type_name]}
              label={gettext("Salary Type")}
              phx-hook="tributeAutoComplete"
              phx-debounce="500"
              url={"/api/companies/#{@current_company.id}/#{@current_user.id}/autocomplete?schema=salarytype&name="}
            />
          </div>
        </div>
        <div class="grid grid-cols-12 gap-1">
          <div class="col-span-3">
            <.input field={@form[:start_date]} label={gettext("Start Date")} type="date" />
          </div>
          <div class="col-span-6">
            <.input field={@form[:descriptions]} label={gettext("Descriptions")} />
          </div>
          <div class="col-span-3">
            <.input
              field={@form[:amount]}
              label={gettext("Recurring Amount")}
              type="number"
              step="0.0001"
            />
          </div>
        </div>
        <div class="grid grid-cols-12 gap-1">
        <div class="col-span-4">
            <.input
              field={@form[:target_amount]}
              label={gettext("Target Amount")}
              type="number"
              step="0.0001"
            />
          </div>
          <div class="col-span-4">
            <.input field={@form[:status]} label={gettext("Status")} type="select" options={["Active", "Finish", "Hold"]} />
          </div>
        </div>

        <div class="flex justify-center gap-x-1 mt-1">
          <.form_action_button
            form={@form}
            live_action={@live_action}
            new_url={~p"/companies/#{@current_company.id}/recurrings/new"}
          />
          <.live_component
            :if={@live_action != :new}
            module={FullCircleWeb.LogLive.Component}
            id={"log_#{@id}"}
            show_log={false}
            entity="recurrings"
            entity_id={@id}
          />
        </div>
      </.form>
    </div>
    """
  end
end
