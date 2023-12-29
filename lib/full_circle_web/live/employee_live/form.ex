defmodule FullCircleWeb.EmployeeLive.Form do
  use FullCircleWeb, :live_view

  alias FullCircle.HR.{Employee}
  alias FullCircle.HR
  alias FullCircle.StdInterface

  @impl true
  def mount(params, _session, socket) do
    id = params["employee_id"]

    socket =
      case socket.assigns.live_action do
        :new -> mount_new(socket)
        :edit -> mount_edit(socket, id)
        :copy -> mount_copy(socket, id)
      end

    {:ok, socket}
  end

  defp mount_new(socket) do
    socket
    |> assign(live_action: :new)
    |> assign(id: "new")
    |> assign(page_title: gettext("New Employee"))
    |> assign(
      :form,
      to_form(StdInterface.changeset(Employee, %Employee{}, %{}, socket.assigns.current_company))
    )
  end

  defp mount_edit(socket, id) do
    obj =
      HR.get_employee!(id, socket.assigns.current_company, socket.assigns.current_user)

    socket
    |> assign(live_action: :edit)
    |> assign(id: id)
    |> assign(page_title: gettext("Edit Employee"))
    |> assign(
      :form,
      to_form(StdInterface.changeset(Employee, obj, %{}, socket.assigns.current_company))
    )
  end

  defp mount_copy(socket, id) do
    obj =
      HR.get_employee!(id, socket.assigns.current_company, socket.assigns.current_user)

    socket
    |> assign(live_action: :new)
    |> assign(id: "new")
    |> assign(page_title: gettext("Copying Employee"))
    |> assign(current_company: socket.assigns.current_company)
    |> assign(current_user: socket.assigns.current_user)
    |> assign(
      :form,
      to_form(
        StdInterface.changeset(
          Employee,
          %Employee{},
          dup_employee(obj),
          socket.assigns.current_company
        )
      )
    )
  end

  @impl true
  def handle_event(
        "validate",
        %{
          "_target" => ["employee", "employee_salary_types", id, "salary_type_name"],
          "employee" => params
        },
        socket
      ) do
    detail = params["employee_salary_types"][id]

    {detail, socket, _} =
      FullCircleWeb.Helpers.assign_autocomplete_id(
        socket,
        detail,
        "salary_type_name",
        "salary_type_id",
        &FullCircle.HR.get_salary_type_by_name/3
      )

    params =
      params
      |> FullCircleWeb.Helpers.merge_detail("employee_salary_types", id, detail)

    validate(params, socket)
  end

  @impl true
  def handle_event("add_salary_type", _, socket) do
    cs =
      socket.assigns.form.source
      |> FullCircleWeb.Helpers.add_line(:employee_salary_types)
      |> Map.put(:action, socket.assigns.live_action)

    {:noreply, socket |> assign(form: to_form(cs))}
  end

  @impl true
  def handle_event("delete_salary_type", %{"index" => index}, socket) do
    cs =
      socket.assigns.form.source
      |> FullCircleWeb.Helpers.delete_line(index, :employee_salary_types)
      |> Map.put(:action, socket.assigns.live_action)

    {:noreply, socket |> assign(form: to_form(cs))}
  end

  def handle_event("validate", %{"employee" => params}, socket) do
    validate(params, socket)
  end

  @impl true
  def handle_event("save", %{"employee" => params}, socket) do
    save(socket, socket.assigns.live_action, params)
  end

  @impl true
  def handle_event("delete", _params, socket) do
    case StdInterface.delete(
           Employee,
           "employee",
           socket.assigns.form.data,
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, _ac} ->
        {:noreply,
         socket
         |> push_navigate(to: "/companies/#{socket.assigns.current_company.id}/employees")
         |> put_flash(:info, "#{gettext("Employee deleted successfully.")}")}

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
    case StdInterface.create(
           Employee,
           "employee",
           params,
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, ac} ->
        {:noreply,
         socket
         |> push_navigate(
           to: ~p"/companies/#{socket.assigns.current_company.id}/employees/#{ac.id}/edit"
         )
         |> put_flash(:info, "#{gettext("Employee created successfully.")}")}

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
           Employee,
           "employee",
           socket.assigns.form.data,
           params,
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, ac} ->
        {:noreply,
         socket
         |> push_navigate(
           to: ~p"/companies/#{socket.assigns.current_company.id}/employees/#{ac.id}/edit"
         )
         |> put_flash(:info, "#{gettext("Employee updated successfully.")}")}

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
        Employee,
        socket.assigns.form.data,
        params,
        socket.assigns.current_company
      )
      |> Map.put(:action, socket.assigns.live_action)

    socket = assign(socket, form: to_form(changeset))

    {:noreply, socket}
  end

  defp dup_employee(object) do
    %{
      name: object.name <> " - Copy",
      id_no: "",
      gender: object.gender,
      epf_no: "",
      socso_no: "",
      tax_no: "",
      marital_status: object.marital_status,
      nationality: object.nationality,
      partner_working: object.partner_working,
      children: object.children,
      status: object.status,
      employee_salary_types: dup_salary_types(object.employee_salary_types)
    }
  end

  defp dup_salary_types(objects) do
    objects
    |> Enum.map(fn x ->
      %{
        salary_type_id: x.salary_type_id,
        salary_type_name: x.salary_type_name,
        amount: x.amount
      }
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="w-7/12 mx-auto border rounded-lg border-yellow-500 bg-yellow-100 p-4">
      <p class="w-full text-3xl text-center font-medium"><%= @page_title %></p>
      <.form
        for={@form}
        id="object-form"
        autocomplete="off"
        phx-change="validate"
        phx-submit="save"
        class="mx-auto"
      >
        <div class="flex flex-nowrap gap-1">
          <div class="w-[35%]">
            <.input field={@form[:name]} label={gettext("Name")} />
          </div>
          <div class="w-[13%]">
            <.input
              field={@form[:gender]}
              label={gettext("Gender")}
              type="select"
              options={["Male", "Female"]}
            />
          </div>
          <div class="w-[20%]">
            <.input field={@form[:nationality]} label={gettext("Nationality")} list="countries" />
          </div>
          <div class="w-[17%]">
            <.input field={@form[:dob]} label={gettext("DOB")} type="date" />
          </div>
        </div>
        <div class="flex flex-nowrap gap-1">
          <div class="w-[14%]">
            <.input
              field={@form[:marital_status]}
              label={gettext("Married")}
              type="select"
              options={["Single", "Married"]}
            />
          </div>
          <div class="w-[15%]">
            <.input
              field={@form[:partner_working]}
              label={gettext("Spouse Working")}
              type="select"
              options={["Yes", "No"]}
            />
          </div>
          <div class="w-[8%]">
            <.input field={@form[:children]} label={gettext("Children")} type="number" step="1" />
          </div>
          <div class="w-[18%]">
            <.input field={@form[:service_since]} label={gettext("Service Since")} type="date" />
          </div>
          <div class="w-[18%]">
            <.input
              field={@form[:contract_expire_date]}
              label={gettext("Contract Expire")}
              type="date"
            />
          </div>
          <div class="w-[15%]">
            <.input
              field={@form[:work_hours_per_day]}
              label={gettext("Work Hours Daily")}
              type="number"
            />
          </div>
        </div>
        <div class="flex flex-nowrap gap-1">
          <div class="w-[16%]">
            <.input
              field={@form[:work_days_per_week]}
              label={gettext("Work Days Weekly")}
              type="number"
            />
          </div>
          <div class="w-[16%]">
            <.input
              field={@form[:work_days_per_month]}
              label={gettext("Work Days Monthly")}
              type="number"
            />
          </div>
          <div class="w-[12%]">
            <.input field={@form[:annual_leave]} label={gettext("Annual Leave")} type="number" />
          </div>
          <div class="w-[10%]">
            <.input field={@form[:sick_leave]} label={gettext("Sick Leave")} type="number" />
          </div>
          <div class="w-[15%]">
            <.input field={@form[:hospital_leave]} label={gettext("Hopistalize Leave")} type="number" />
          </div>
          <div class="w-[14%]">
            <.input field={@form[:maternity_leave]} label={gettext("Maternity Leave")} type="number" />
          </div>
          <div class="w-[13%]">
            <.input field={@form[:paternity_leave]} label={gettext("Paternity Leave")} type="number" />
          </div>
        </div>
        <div class="flex flex-nowrap gap-1">
          <div class="w-[21%]">
            <.input field={@form[:id_no]} label={gettext("Id No")} />
          </div>
          <div class="w-[21%]">
            <.input field={@form[:epf_no]} label={gettext("EPF No")} />
          </div>
          <div class="w-[21%]">
            <.input field={@form[:socso_no]} label={gettext("SOCSO No")} />
          </div>
          <div class="w-[21%]">
            <.input field={@form[:tax_no]} label={gettext("Tax No")} />
          </div>
          <div class="w-[15%]">
            <.input
              field={@form[:status]}
              label={gettext("Status")}
              type="select"
              options={["Active", "Resigned"]}
            />
          </div>
        </div>
        <.input field={@form[:note]} label={gettext("Note")} />
        <%= datalist(FullCircle.Sys.countries(), "countries") %>

        <div class="font-bold grid grid-cols-12 gap-2 mt-2 text-center">
          <div class="col-span-6">
            <%= gettext("Salary Type") %>
          </div>
          <div class="col-span-6">
            <%= gettext("Amount") %>
          </div>
        </div>
        <.inputs_for :let={st} field={@form[:employee_salary_types]}>
          <div class={"grid grid-cols-12 gap-1 #{if(st[:delete].value == true and Enum.count(st.errors) == 0, do: "hidden", else: "")}"}>
            <div class="col-span-6">
              <%= Phoenix.HTML.Form.hidden_input(st, :employee_id) %>
              <%= Phoenix.HTML.Form.hidden_input(st, :salary_type_id) %>
              <.input
                field={st[:salary_type_name]}
                phx-hook="tributeAutoComplete"
                phx-debounce="500"
                url={"/api/companies/#{@current_company.id}/#{@current_user.id}/autocomplete?schema=salarytype&name="}
              />
            </div>
            <div class="col-span-5">
              <.input type="number" field={st[:amount]} step="0.0001" />
            </div>
            <div class="col-span-1 mt-1.5 text-rose-500">
              <.link phx-click={:delete_salary_type} phx-value-index={st.index}>
                <Heroicons.trash solid class="h-5 w-5" />
              </.link>
              <%= Phoenix.HTML.Form.hidden_input(st, :delete) %>
            </div>
          </div>
        </.inputs_for>

        <div class="my-2">
          <.link phx-click={:add_salary_type} class="text-orange-500 hover:font-bold focus:font-bold">
            <.icon name="hero-plus-circle" class="w-5 h-5" /><%= gettext("Add Salary Type") %>
          </.link>
        </div>

        <div class="flex justify-center gap-x-1 mt-1">
          <.form_action_button
            form={@form}
            live_action={@live_action}
            current_company={@current_company}
            type="employees"
          />
          <%= if @live_action == :edit and FullCircle.Authorization.can?(@current_user, :delete_tax_code, @current_company) do %>
            <.delete_confirm_modal
              id="delete-object"
              msg1={gettext("All Employee Transactions, will be LOST!!!")}
              msg2={gettext("Cannot Be Recover!!!")}
              confirm={
                JS.push("delete", target: "#object-form")
                |> JS.hide(to: "#delete-object-modal")
              }
            />
          <% end %>
          <.print_button
            :if={@live_action != :new}
            company={@current_company}
            doc_type="employees"
            doc_id={@id}
            class="gray button"
          />
          <.live_component
            :if={@live_action != :new}
            module={FullCircleWeb.LogLive.Component}
            id={"log_#{@id}"}
            show_log={false}
            entity="employees"
            entity_id={@id}
          />
        </div>
      </.form>
    </div>
    """
  end
end
