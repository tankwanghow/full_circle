defmodule FullCircleWeb.SalaryNoteLive.Form do
  use FullCircleWeb, :live_view

  alias FullCircle.HR.{SalaryNote}
  alias FullCircle.HR
  alias FullCircle.StdInterface

  @impl true
  def mount(params, _session, socket) do
    id = params["slip_id"]

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
    |> assign(page_title: gettext("New Salary Note"))
    |> assign(
      :form,
      to_form(
        StdInterface.changeset(
          SalaryNote,
          %SalaryNote{},
          %{note_no: "...new..."},
          socket.assigns.current_company
        )
      )
    )
  end

  defp mount_edit(socket, id) do
    obj =
      HR.get_salary_note!(id, socket.assigns.current_company, socket.assigns.current_user)

    socket
    |> assign(live_action: :edit)
    |> assign(id: id)
    |> assign(page_title: gettext("Edit Salary Note") <> " " <> obj.note_no)
    |> assign(
      :form,
      to_form(StdInterface.changeset(SalaryNote, obj, %{}, socket.assigns.current_company))
    )
  end

  def handle_event(
        "validate",
        %{"_target" => ["salary_note", "employee_name"], "salary_note" => params},
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

    st = HR.get_employee_salary_type(params["employee_id"], params["salary_type_id"])

    params = if(st, do: Map.merge(params, %{"unit_price" => st.amount}), else: params)

    validate(params, socket)
  end

  def handle_event(
        "validate",
        %{"_target" => ["salary_note", "salary_type_name"], "salary_note" => params},
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

    st = HR.get_employee_salary_type(params["employee_id"], params["salary_type_id"])

    params = if(st, do: Map.merge(params, %{"unit_price" => st.amount}), else: params)

    validate(params, socket)
  end

  def handle_event("validate", %{"salary_note" => params}, socket) do
    validate(params, socket)
  end

  @impl true
  def handle_event("save", %{"salary_note" => params}, socket) do
    save(socket, socket.assigns.live_action, params)
  end

  @impl true
  def handle_event("delete", _params, socket) do
    case HR.delete_salary_note(
           socket.assigns.form.data,
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, %{delete_salary_note: _obj}} ->
        {:noreply,
         socket
         |> push_navigate(to: ~p"/companies/#{socket.assigns.current_company.id}/SalaryNote")
         |> put_flash(:info, "#{gettext("Salary Note Deleted successfully.")}")}

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

  defp save(socket, :new, params) do
    case(
      HR.create_salary_note(
        params,
        socket.assigns.current_company,
        socket.assigns.current_user
      )
    ) do
      {:ok, %{create_salary_note: obj}} ->
        {:noreply,
         socket
         |> push_navigate(
           to: ~p"/companies/#{socket.assigns.current_company.id}/SalaryNote/#{obj.id}/edit"
         )
         |> put_flash(:info, "#{gettext("Salary Note created successfully.")}")}

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
    case HR.update_salary_note(
           socket.assigns.form.data,
           params,
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, %{update_salary_note: obj}} ->
        {:noreply,
         socket
         |> push_navigate(
           to: ~p"/companies/#{socket.assigns.current_company.id}/SalaryNote/#{obj.id}/edit"
         )
         |> put_flash(:info, "#{gettext("Salary Note updated successfully.")}")}

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
        SalaryNote,
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
    <div class="w-7/12 mx-auto border rounded-lg border-yellow-500 bg-yellow-100 p-4">
      <p class="w-full text-3xl text-center font-medium">{@page_title}</p>
      <div class="text-center">
        <span class="text-xl">PaySlip Info:- </span>
        <.link
          :if={!is_nil(@form.source.data.pay_slip_no)}
          navigate={"/companies/#{@current_company.id}/PaySlip/#{@form.source.data.pay_slip_id}/view"}
          class="text-xl text-blue-600 hover:cursor-pointer hover:font-bold"
        >
          {@form.source.data.pay_slip_no} {FullCircleWeb.Helpers.format_date(
            @form.source.data.pay_slip_date
          )}
        </.link>
      </div>
      <.form
        for={@form}
        id="object-form"
        autocomplete="off"
        phx-change="validate"
        phx-submit="save"
        class="mx-auto"
      >
        <.input type="hidden" field={@form[:note_no]} />
        <div class="grid grid-cols-12 gap-1">
          <div class="col-span-3">
            <.input field={@form[:note_date]} label={gettext("Date")} type="date" feedback={true} />
          </div>
          <div class="col-span-5">
            <.input type="hidden" field={@form[:employee_id]} />
            <.input
              field={@form[:employee_name]}
              label={gettext("Employee")}
              phx-hook="tributeAutoComplete"
              url={"/list/companies/#{@current_company.id}/#{@current_user.id}/autocomplete?schema=employee&name="}
            />
          </div>
          <div class="col-span-4">
            <.input type="hidden" field={@form[:salary_type_id]} />
            <.input
              field={@form[:salary_type_name]}
              label={gettext("Salary Type")}
              phx-hook="tributeAutoComplete"
              url={"/list/companies/#{@current_company.id}/#{@current_user.id}/autocomplete?schema=salarytype&name="}
            />
          </div>
        </div>
        <div class="grid grid-cols-12 gap-1">
          <div class="col-span-12">
            <.input field={@form[:descriptions]} label={gettext("Descriptions")} />
          </div>
        </div>
        <div class="grid grid-cols-12 gap-1">
          <div class="col-span-4">
            <.input
              field={@form[:quantity]}
              label={gettext("Quantity")}
              phx-hook="calculatorInput"
              klass="text-right"
              step="0.0001"
            />
          </div>
          <div class="col-span-4">
            <.input
              field={@form[:unit_price]}
              label={gettext("Price")}
              phx-hook="calculatorInput"
              klass="text-right"
              step="0.0001"
            />
          </div>
          <div class="col-span-4">
            <.input
              feedback={true}
              field={@form[:amount]}
              label={gettext("Amount")}
              type="number"
              readonly
            />
          </div>
        </div>

        <div class="flex justify-center gap-x-1 mt-1">
          <.form_action_button
            form={@form}
            live_action={@live_action}
            current_company={@current_company}
            type="SalaryNote"
          />
          <%= if @live_action == :edit and FullCircle.Authorization.can?(@current_user, :delete_salary_note, @current_company) do %>
            <.delete_confirm_modal
              id="delete-object"
              msg1={gettext("Deleting Salary Note")}
              msg2={gettext("Cannot Be Recover!!!")}
              confirm={
                JS.push("delete", target: "#object-form")
                |> JS.exec("phx-remove", to: "#delete-object-modal")
              }
            />
          <% end %>
          <.print_button
            :if={@live_action == :edit}
            company={@current_company}
            doc_type="SalaryNote"
            doc_id={@id}
            class="gray button"
          />
          <.pre_print_button
            :if={@live_action == :edit}
            company={@current_company}
            doc_type="SalaryNote"
            doc_id={@id}
            class="gray button"
          />
          <.live_component
            :if={@live_action != :new}
            module={FullCircleWeb.LogLive.Component}
            current_company={@current_company}
            id={"log_#{@id}"}
            show_log={false}
            entity="salary_notes"
            entity_id={@id}
          />
          <.live_component
            :if={@live_action == :edit}
            module={FullCircleWeb.JournalEntryViewLive.Component}
            id={"journal_#{@id}"}
            show_journal={false}
            doc_type="SalaryNote"
            doc_no={@form.data.note_no}
            company_id={@current_company.id}
          />
        </div>
      </.form>
    </div>
    """
  end
end
