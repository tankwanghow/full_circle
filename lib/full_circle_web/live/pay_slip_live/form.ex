defmodule FullCircleWeb.PaySlipLive.Form do
  use FullCircleWeb, :live_view

  alias FullCircle.PaySlipOp
  alias FullCircleWeb.PaySlipLive.{SalaryNoteComponent, AdvanceComponent}
  alias FullCircle.HR.PaySlip

  @impl true
  def mount(params, _session, socket) do
    {:ok, mount_view(socket, params["pay_slip_id"])}
  rescue
    Ecto.NoResultsError ->
      {:ok,
       socket
       |> put_flash(:error, gettext("Pay slip not found. It may have been voided."))
       |> push_navigate(to: ~p"/companies/#{socket.assigns.current_company.id}/PayRun")}
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
    |> assign(page_title: gettext("View Pay Slip") <> " " <> obj.slip_no)
    |> assign(
      punch_card_url:
        ~p"/companies/#{socket.assigns.current_company.id}/PunchCard?#{%{"search[employee_name]" => emp.name, "search[month]" => obj.pay_month, "search[year]" => obj.pay_year}}"
    )
    |> assign(form: to_form(cs))
  end

  @impl true
  def handle_event("void", _, socket) do
    case PaySlipOp.void_pay_slip(
           socket.assigns.id,
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, _} ->
        {:noreply, push_event(socket, "history_back", %{})}

      :not_authorise ->
        {:noreply,
         put_flash(socket, :error, gettext("You are not authorised to perform this action"))}

      {:period_closed, deadline} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Voiding for this pay period closed on %{date}", date: deadline)
         )}

      {:sql_error, msg} ->
        {:noreply, put_flash(socket, :error, "#{gettext("Failed")} #{msg}")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="w-8/12 mx-auto border rounded-lg border-yellow-500 bg-yellow-100 p-4">
      <p class="w-full text-3xl text-center font-medium">{@page_title}</p>
      <.form for={@form} id="object-form" autocomplete="off" class="mx-auto">
        <.input type="hidden" field={@form[:slip_no]} />
        <div class="flex flex-nowrap gap-1 mb-2">
          <div class="w-[25%]">
            <.input type="hidden" field={@form[:employee_id]} />
            <.input field={@form[:employee_name]} label={gettext("Employee")} readonly tabindex="-1" />
          </div>
          <div class="w-[15%]">
            <.input
              field={@form[:slip_date]}
              label={gettext("Date")}
              type="date"
              readonly
              tabindex="-1"
            />
          </div>
          <div class="w-[7%]">
            <.input
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
              readonly
              tabindex="-1"
            />
          </div>
        </div>

        <div class="flex flex-row text-center font-semibold">
          <div class="w-[14%]">{gettext("Doc Date")}</div>
          <div class="w-[13%]">{gettext("Doc No")}</div>
          <div class="w-[21%]">{gettext("Salary Type")}</div>
          <div class="w-[24%]">{gettext("Description")}</div>
          <div class="w-[8%]">{gettext("Quantity")}</div>
          <div class="w-[9%]">{gettext("Price")}</div>
          <div class="w-[11%]">{gettext("Amount")}</div>
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
            {gettext("Pay Slip Total")}
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
          <.link navigate={@punch_card_url} class="orange button">
            {gettext("Edit in Punch Card")}
          </.link>
          <.link navigate={~p"/companies/#{@current_company.id}/PayRun"} class="blue button">
            {gettext("Pay Run")}
          </.link>
          <.link
            phx-click="void"
            data-confirm={
              gettext(
                "Void this Pay Slip? Its notes/advances stay as unprocessed; the slip and its GL postings are removed."
              )
            }
            class="red button"
          >
            {gettext("Void PaySlip")}
          </.link>
          <a onclick="history.back();" class="blue button">{gettext("Back")}</a>
          <.print_button
            company={@current_company}
            doc_type="PaySlip"
            doc_id={@id}
            class="gray button"
          />
          <.pre_print_button
            company={@current_company}
            doc_type="PaySlip"
            doc_id={@id}
            class="gray button"
          />
          <.live_component
            module={FullCircleWeb.LogLive.Component}
            current_company={@current_company}
            id={"log_#{@id}"}
            show_log={false}
            entity="pay_slips"
            entity_id={@id}
          />
          <.live_component
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
