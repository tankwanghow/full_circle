defmodule FullCircleWeb.SalaryTypeLive.Form do
  use FullCircleWeb, :live_view

  alias FullCircle.HR.{SalaryType}
  alias FullCircle.HR
  alias FullCircle.StdInterface

  @impl true
  def mount(params, _session, socket) do
    id = params["type_id"]

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
    |> assign(page_title: gettext("New Salary Type"))
    |> assign(
      :form,
      to_form(
        StdInterface.changeset(SalaryType, %SalaryType{}, %{}, socket.assigns.current_company)
      )
    )
  end

  defp mount_edit(socket, id) do
    obj =
      HR.get_salary_type!(id, socket.assigns.current_company, socket.assigns.current_user)

    socket
    |> assign(live_action: :edit)
    |> assign(id: id)
    |> assign(page_title: gettext("Edit Salary Type"))
    |> assign(
      :form,
      to_form(StdInterface.changeset(SalaryType, obj, %{}, socket.assigns.current_company))
    )
  end

  # Default salary types keep their seeded type, except the wage defaults
  # (Monthly/Daily/Hourly Salary etc.), which may flip between Addition and
  # FixedWages — the FixedWages subset is the HRD Corp levy base.
  defp type_locked?(st) do
    HR.is_default_salary_type?(st) and st.type not in HR.wage_types()
  end

  defp type_options(st) do
    if HR.is_default_salary_type?(st) and st.type in HR.wage_types() do
      HR.wage_types()
    else
      HR.salary_type_types()
    end
  end

  # everything validate_cal_func accepts: legacy funcs + imported calc codes
  defp cal_func_options(company_id) do
    (FullCircle.PaySlipOp.legacy_cal_funcs() ++
       FullCircle.StatutoryConfig.calc_codes(company_id))
    |> Enum.uniq()
    |> Enum.sort()
  end

  def handle_event(
        "validate",
        %{"_target" => ["salary_type", "db_ac_name"], "salary_type" => params},
        socket
      ) do
    {params, socket, _} =
      FullCircleWeb.Helpers.assign_autocomplete_id(
        socket,
        params,
        "db_ac_name",
        "db_ac_id",
        &FullCircle.Accounting.get_account_by_name/3
      )

    validate(params, socket)
  end

  def handle_event(
        "validate",
        %{"_target" => ["salary_type", "cr_ac_name"], "salary_type" => params},
        socket
      ) do
    {params, socket, _} =
      FullCircleWeb.Helpers.assign_autocomplete_id(
        socket,
        params,
        "cr_ac_name",
        "cr_ac_id",
        &FullCircle.Accounting.get_account_by_name/3
      )

    validate(params, socket)
  end

  def handle_event("validate", %{"salary_type" => params}, socket) do
    validate(params, socket)
  end

  @impl true
  def handle_event("save", %{"salary_type" => params}, socket) do
    save(socket, socket.assigns.live_action, params)
  end

  @impl true
  def handle_event("delete", _params, socket) do
    case StdInterface.delete(
           SalaryType,
           "salary_type",
           socket.assigns.form.data,
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, _ac} ->
        {:noreply,
         socket
         |> push_navigate(to: "/companies/#{socket.assigns.current_company.id}/salary_types")
         |> put_flash(:info, "#{gettext("Salary Type deleted successfully.")}")}

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
           SalaryType,
           "salary_type",
           params,
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, ac} ->
        {:noreply,
         socket
         |> push_navigate(
           to: ~p"/companies/#{socket.assigns.current_company.id}/salary_types/#{ac.id}/edit"
         )
         |> put_flash(:info, "#{gettext("Salary Type created successfully.")}")}

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
           SalaryType,
           "salary_type",
           socket.assigns.form.data,
           params,
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, ac} ->
        {:noreply,
         socket
         |> push_navigate(
           to: ~p"/companies/#{socket.assigns.current_company.id}/salary_types/#{ac.id}/edit"
         )
         |> put_flash(:info, "#{gettext("Salary Type updated successfully.")}")}

      {:error, :stale} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           gettext(
             "This record was changed or deleted by someone else. Please reload and try again."
           )
         )}

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
        SalaryType,
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
      <p class="w-full text-3xl text-center font-medium">{@page_title}</p>
      <.form
        for={@form}
        id="object-form"
        autocomplete="off"
        phx-change="validate"
        phx-submit="save"
        class="mx-auto"
      >
        <div class="grid grid-cols-12 gap-1">
          <div class="col-span-5">
            <.input
              field={@form[:name]}
              readonly={FullCircle.HR.is_default_salary_type?(@form.data)}
              label={gettext("Name")}
            />
          </div>
          <div class="col-span-3">
            <.input
              disabled={type_locked?(@form.data)}
              field={@form[:type]}
              label={gettext("Type")}
              type="select"
              options={type_options(@form.data)}
            />
          </div>
          <div class="col-span-4">
            <.input
              field={@form[:cal_func]}
              label={gettext("Calculation Function")}
              type="select"
              prompt={gettext("— none —")}
              options={cal_func_options(@current_company.id)}
            />
          </div>
        </div>
        <div class="grid grid-cols-12 gap-1">
          <div class="col-span-4">
            <.input
              field={@form[:statutory_code]}
              type="select"
              label={gettext("Statutory Code")}
              prompt={gettext("— none —")}
              options={FullCircle.HR.statutory_categories(@current_company.id)}
            />
          </div>
          <div class="col-span-4">
            <.input type="hidden" field={@form[:db_ac_id]} />
            <.input
              field={@form[:db_ac_name]}
              label={gettext("Debit Account")}
              phx-hook="tributeAutoComplete"
              url={"/list/companies/#{@current_company.id}/#{@current_user.id}/autocomplete?schema=account&name="}
            />
          </div>
          <div class="col-span-4">
            <.input type="hidden" field={@form[:cr_ac_id]} />
            <.input
              field={@form[:cr_ac_name]}
              label={gettext("Credit Account")}
              phx-hook="tributeAutoComplete"
              url={"/list/companies/#{@current_company.id}/#{@current_user.id}/autocomplete?schema=account&name="}
            />
          </div>
        </div>

        <div class="flex justify-center gap-x-1 mt-1">
          <.form_action_button
            form={@form}
            live_action={@live_action}
            current_company={@current_company}
            type="salary_types"
          />
          <%= if @live_action == :edit and FullCircle.Authorization.can?(@current_user, :delete_tax_code, @current_company) do %>
            <.delete_confirm_modal
              id="delete-object"
              msg1={gettext("All SalaryType Transactions, will be LOST!!!")}
              msg2={gettext("Cannot Be Recover!!!")}
              confirm={
                JS.push("delete", target: "#object-form")
                |> JS.hide(to: "#delete-object-modal")
              }
            />
          <% end %>
          <.live_component
            :if={@live_action != :new}
            module={FullCircleWeb.LogLive.Component}
            current_company={@current_company}
            id={"log_#{@id}"}
            show_log={false}
            entity="salary_types"
            entity_id={@id}
          />
        </div>
      </.form>
    </div>
    """
  end
end
