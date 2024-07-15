defmodule FullCircleWeb.PaySlipLive.Form do
  use FullCircleWeb, :live_view

  alias FullCircle.PaySlipOp
  alias FullCircleWeb.PaySlipLive.{SalaryNoteComponent, AdvanceComponent}
  alias FullCircle.StdInterface
  alias FullCircle.HR.PaySlip

  @impl true
  def mount(params, _session, socket) do
    month = params["month"]
    year = params["year"]
    emp_id = params["emp_id"]
    id = params["pay_slip_id"]

    socket =
      case socket.assigns.live_action do
        :new ->
          mount_new(socket, emp_id, month |> String.to_integer(), year |> String.to_integer())

        :view ->
          mount_view(socket, id)

        :recal ->
          mount_recal(socket, id)
      end

    {:ok, socket}
  end

  defp mount_new(socket, emp_id, month, year) do
    emp =
      FullCircle.HR.get_employee!(
        emp_id,
        socket.assigns.current_company,
        socket.assigns.current_user
      )

    cs =
      PaySlipOp.generate_new_changeset_for(
        emp,
        month,
        year,
        socket.assigns.current_company,
        socket.assigns.current_user
      )
      |> PaySlipOp.calculate_pay(emp)

    socket
    |> assign(live_action: :new)
    |> assign(id: "new")
    |> assign(page_title: gettext("New Pay Slip"))
    |> assign(employee: emp)
    |> assign(form: to_form(cs))
  end

  defp mount_view(socket, id) do
    obj =
      PaySlipOp.get_pay_slip!(id, socket.assigns.current_company)

    emp =
      FullCircle.HR.get_employee!(
        obj.employee_id,
        socket.assigns.current_company,
        socket.assigns.current_user
      )

    cs = PaySlip.changeset(obj, %{})

    socket
    |> assign(live_action: :view)
    |> assign(id: id)
    |> assign(employee: emp)
    |> assign(page_title: gettext("Edit Pay Slip") <> " " <> obj.slip_no)
    |> assign(form: to_form(cs))
  end

  defp mount_recal(socket, id) do
    obj =
      PaySlipOp.get_recal_pay_slip(
        id,
        socket.assigns.current_company,
        socket.assigns.current_user
      )

    emp =
      FullCircle.HR.get_employee!(
        obj.employee_id,
        socket.assigns.current_company,
        socket.assigns.current_user
      )

    cs = PaySlip.changeset(obj, %{})

    socket
    |> assign(live_action: :edit)
    |> assign(id: id)
    |> assign(employee: emp)
    |> assign(page_title: gettext("Edit Pay Slip") <> " " <> obj.slip_no)
    |> assign(form: to_form(cs))
  end

  @impl true
  def handle_event("exec_cal_func", _, socket) do
    cs = PaySlipOp.calculate_pay(socket.assigns.form.source, socket.assigns.employee)

    socket = assign(socket, form: to_form(cs))

    {:noreply, socket}
  end

  @impl true
  def handle_event("save", %{"pay_slip" => params}, socket) do
    save(socket, socket.assigns.live_action, params)
  end

  @impl true
  def handle_event(
        "validate",
        %{"_target" => ["pay_slip", "funds_account_name"], "pay_slip" => params},
        socket
      ) do
    {params, socket, _} =
      FullCircleWeb.Helpers.assign_autocomplete_id(
        socket,
        params,
        "funds_account_name",
        "funds_account_id",
        &FullCircle.Accounting.get_account_by_name/3
      )

    validate(params, socket)
  end

  @impl true
  def handle_event("validate", %{"pay_slip" => params}, socket) do
    validate(params, socket)
  end

  defp save(socket, :new, params) do
    case PaySlipOp.create_pay_slip(
           params,
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, %{create_pay_slip: obj}} ->
        {:noreply,
         socket
         |> push_navigate(
           to: ~p"/companies/#{socket.assigns.current_company.id}/PaySlip/#{obj.id}/view"
         )
         |> put_flash(:info, "#{gettext("Pay Slip created successfully.")}")}

      {:error, failed_operation, changeset, _} ->
        {:noreply,
         socket
         |> assign(form: to_form(changeset))
         |> put_flash(
           :error,
           "#{gettext("Failed")} #{failed_operation}. #{list_errors_to_string(changeset.errors)}"
         )}

      {:sql_error, msg} ->
        {:noreply,
         socket
         |> put_flash(:error, "#{gettext("Failed")} #{msg}")}

      :not_authorise ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("You are not authorised to perform this action"))}
    end
  end

  defp save(socket, :edit, params) do
    case PaySlipOp.update_pay_slip(
           socket.assigns.form.data,
           params,
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, %{update_pay_slip: obj}} ->
        {:noreply,
         socket
         |> push_navigate(
           to: ~p"/companies/#{socket.assigns.current_company.id}/PaySlip/#{obj.id}/view"
         )
         |> put_flash(:info, "#{gettext("Pay Slip Updated successfully.")}")}

      {:error, failed_operation, changeset, _} ->
        {:noreply,
         socket
         |> assign(form: to_form(changeset))
         |> put_flash(
           :error,
           "#{gettext("Failed")} #{failed_operation}. #{list_errors_to_string(changeset.errors)}"
         )}

      {:sql_error, msg} ->
        {:noreply,
         socket
         |> put_flash(:error, "#{gettext("Failed")} #{msg}")}

      :not_authorise ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("You are not authorised to perform this action"))}
    end
  end

  defp validate(params, socket) do
    changeset =
      StdInterface.changeset(
        PaySlip,
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
    <div class="w-8/12 mx-auto border rounded-lg border-yellow-500 bg-yellow-100 p-4">
      <p class="w-full text-3xl text-center font-medium"><%= @page_title %></p>
      <.form
        for={@form}
        id="object-form"
        autocomplete="off"
        phx-change="validate"
        phx-submit="save"
        class="mx-auto"
      >
        <.input type="hidden" field={@form[:slip_no]} />
        <div class="flex flex-nowrap gap-1 mb-2">
          <div class="w-[25%]">
            <.input type="hidden" field={@form[:employee_id]} />
            <.input field={@form[:employee_name]} label={gettext("Employee")} readonly tabindex="-1" />
          </div>
          <div class="w-[15%]">
            <.input feedback={true} field={@form[:slip_date]} label={gettext("Date")} type="date" />
          </div>
          <div class="w-[7%]">
            <.input
              feedback={true}
              field={@form[:pay_month]}
              label={gettext("Month")}
              type="number"
              readonly
              tabindex="-1"
            />
          </div>
          <div class="w-[7%]">
            <.input
              field={@form[:pay_year]}
              label={gettext("Year")}
              type="number"
              readonly
              tabindex="-1"
            />
          </div>
          <div class="w-[20%]">
            <.input type="hidden" field={@form[:funds_account_id]} />
            <.input
              field={@form[:funds_account_name]}
              label={gettext("Funds From")}
              phx-hook="tributeAutoComplete"
              url={"/list/companies/#{@current_company.id}/#{@current_user.id}/autocomplete?schema=fundsaccount&name="}
            />
          </div>
          <.link
            :if={@live_action == :edit}
            phx-click={JS.push("exec_cal_func")}
            class="mt-4 blue button"
          >
            <%= gettext("Calculate") %>
          </.link>
        </div>

        <div class="flex flex-row text-center font-semibold">
          <div class="w-[14%]"><%= gettext("Doc Date") %></div>
          <div class="w-[13%]"><%= gettext("Doc No") %></div>
          <div class="w-[21%]"><%= gettext("Salary Type") %></div>
          <div class="w-[24%]"><%= gettext("Description") %></div>
          <div class="w-[8%]"><%= gettext("Quantity") %></div>
          <div class="w-[9%]"><%= gettext("Price") %></div>
          <div class="w-[11%]"><%= gettext("Amount") %></div>
          <div class="w-[2%]"></div>
        </div>

        <.live_component
          module={SalaryNoteComponent}
          id="additions"
          klass="Addition"
          types={@form[:additions]}
          total_field={@form[:addition_amount]}
          total_label={gettext("Addition Amount")}
          current_company={@current_company}
          current_user={@current_user}
        />

        <.live_component
          module={SalaryNoteComponent}
          id="bonuses"
          klass="Bonus"
          types={@form[:bonuses]}
          total_field={@form[:bonus_amount]}
          total_label={nil}
          current_company={@current_company}
          current_user={@current_user}
        />

        <.live_component
          module={AdvanceComponent}
          id="advances"
          types={@form[:advances]}
          total_field={@form[:advance_amount]}
          total_label={gettext("Advance Amount")}
          current_company={@current_company}
          current_user={@current_user}
        />

        <.live_component
          module={SalaryNoteComponent}
          id="deductions"
          klass="Deduction"
          types={@form[:deductions]}
          total_field={@form[:deduction_amount]}
          total_label={gettext("Deduction Amount")}
          current_company={@current_company}
          current_user={@current_user}
        />

        <div class="flex flex-row text-center font-semibold mb-5">
          <div class="w-[89%] text-right px-1 pt-1">
            <%= gettext("Pay Slip Total") %>
          </div>
          <div class="w-[11%]">
            <.input readonly tabindex="-1" field={@form[:pay_slip_amount]} type="number" />
          </div>
        </div>

        <.live_component
          module={SalaryNoteComponent}
          id="contributions"
          klass="Contribution"
          types={@form[:contributions]}
          total_field={0}
          total_label={nil}
          current_company={@current_company}
          current_user={@current_user}
        />

        <.live_component
          module={SalaryNoteComponent}
          id="leaves"
          klass="LeaveTaken"
          types={@form[:leaves]}
          total_field={0}
          total_label={nil}
          current_company={@current_company}
          current_user={@current_user}
        />

        <div class="flex flex-row justify-center gap-x-1 mt-1">
          <%= if @live_action != :view do %>
            <.save_button form={@form} />
          <% end %>
          <a onclick="history.back();" class="blue button"><%= gettext("Back") %></a>
          <.print_button
            :if={@live_action == :view}
            company={@current_company}
            doc_type="PaySlip"
            doc_id={@id}
            class="gray button"
          />
          <.pre_print_button
            :if={@live_action == :view}
            company={@current_company}
            doc_type="PaySlip"
            doc_id={@id}
            class="gray button"
          />
          <.live_component
            :if={@live_action == :view}
            module={FullCircleWeb.LogLive.Component}
            current_company={@current_company}
            id={"log_#{@id}"}
            show_log={false}
            entity="pay_slips"
            entity_id={@id}
          />
          <.live_component
            :if={@live_action == :view}
            module={FullCircleWeb.JournalEntryViewLive.Component}
            id={"journal_#{@id}"}
            show_journal={false}
            doc_type="PaySlip"
            doc_no={@form.data.slip_no}
            company_id={@current_company.id}
          />
        </div>
      </.form>
    </div>
    """
  end
end
