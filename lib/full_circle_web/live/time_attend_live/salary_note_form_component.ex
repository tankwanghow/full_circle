defmodule FullCircleWeb.TimeAttendLive.SalaryNoteFormComponent do
  use FullCircleWeb, :live_component

  alias FullCircle.HR.{SalaryNote}
  alias FullCircle.HR
  alias FullCircle.StdInterface

  @impl true
  def mount(socket) do
    {:ok, socket}
  end

  @impl true
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign(
       :form,
       to_form(
         StdInterface.changeset(
           SalaryNote,
           assigns.obj,
           %{},
           assigns.current_company
         )
       )
     )}
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
      {:ok, %{delete_salary_note: obj}} ->
        send(self(), {:refresh_page_sn, obj})
        {:noreply, socket}

      {:error, _failed_operation, changeset, _} ->
        send(self(), {:error_refresh_page_sn, changeset})
        {:noreply, socket}

      :not_authorise ->
        send(self(), {:not_authorise})
        {:noreply, socket}
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
        send(self(), {:refresh_page_sn, obj})
        {:noreply, socket}

      {:error, _failed_operation, changeset, _} ->
        send(self(), {:error_refresh_page_sn, changeset})
        {:noreply, socket}

      :not_authorise ->
        send(self(), {:not_authorise})
        {:noreply, socket}
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
        send(self(), {:refresh_page_sn, obj})
        {:noreply, socket}

      {:error, _failed_operation, changeset, _} ->
        send(self(), {:error_refresh_page_sn, changeset})
        {:noreply, socket}

      :not_authorise ->
        send(self(), {:not_authorise})
        {:noreply, socket}
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
    <div class="">
      <.form
        for={@form}
        id="object-form"
        autocomplete="off"
        phx-change="validate"
        phx-submit="save"
        phx-target={@myself}
      >
        <p class="w-full text-3xl text-center font-medium">{@title}</p>
        <p :if={!is_nil(@form.source.data.pay_slip_no)} class="w-full text-xl text-center">
          {@form.source.data.pay_slip_no} {FullCircleWeb.Helpers.format_date(
            @form.source.data.pay_slip_date
          )}
        </p>
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
          <div class="col-span-6">
            <.input field={@form[:descriptions]} label={gettext("Descriptions")} />
          </div>
          <div class="col-span-2">
            <.input field={@form[:quantity]} label={gettext("Quantity")} type="number" step="0.0001" />
          </div>
          <div class="col-span-2">
            <.input field={@form[:unit_price]} label={gettext("Price")} type="number" step="0.0001" />
          </div>
          <div class="col-span-2">
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
          <.save_button form={@form} />
          <.link phx-click={:modal_cancel} class="orange button">
            {gettext("Cancel")}
          </.link>
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
